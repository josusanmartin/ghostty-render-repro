package renderbench

const DefaultClusterLen = 2
const MaxClusterLen = 8

type Cell struct {
	Codepoint uint32
	CombLen   uint16
	Combining [MaxClusterLen]uint32
	Fg        uint32
	Bg        uint32
	Attr      uint16
}

type Row struct {
	Version uint64
	Cells   []Cell
}

type Screen struct {
	Rows       []Row
	Cols       int
	CursorX    int
	CursorY    int
	Frame      uint64
	PaletteRev uint64
}

func NewScreen(rows, cols int) *Screen {
	return NewScreenWithCluster(rows, cols, DefaultClusterLen)
}

func NewScreenWithCluster(rows, cols, clusterLen int) *Screen {
	if clusterLen < 0 || clusterLen > MaxClusterLen {
		panic("invalid cluster length")
	}
	s := &Screen{
		Rows: make([]Row, rows),
		Cols: cols,
	}
	for y := range s.Rows {
		row := &s.Rows[y]
		row.Version = 1
		row.Cells = make([]Cell, cols)
		for x := range row.Cells {
			row.Cells[x] = makeCell(x, y, 1, clusterLen)
		}
	}
	return s
}

func makeCell(x, y int, frame uint64, clusterLen int) Cell {
	base := uint32('a') + uint32((x+y+int(frame))%26)
	c := Cell{
		Codepoint: base,
		CombLen:   uint16(clusterLen),
		Fg:        0x00d0d0d0 ^ uint32((x*17+y*11)&0xff),
		Bg:        0x00101010 ^ uint32((x*7+y*13)&0xff),
		Attr:      uint16((x + y) & 7),
	}
	for i := 0; i < clusterLen; i++ {
		c.Combining[i] = 0x300 + uint32((x*3+y*5+i*7+int(frame))%512)
	}
	return c
}

func AdvanceFrame(s *Screen, dirtyRows int) {
	if dirtyRows <= 0 || len(s.Rows) == 0 {
		return
	}
	s.Frame++
	s.CursorX = int((s.Frame * 7) % uint64(s.Cols))
	s.CursorY = int((s.Frame * 11) % uint64(len(s.Rows)))
	for i := 0; i < dirtyRows; i++ {
		y := int((s.Frame*17 + uint64(i)*131) % uint64(len(s.Rows)))
		row := &s.Rows[y]
		row.Version++
		for x := range row.Cells {
			c := &row.Cells[x]
			c.Codepoint = uint32('A') + uint32((x+y+int(s.Frame))%26)
			for j := 0; j < int(c.CombLen); j++ {
				c.Combining[j] = 0x300 + uint32((x*3+y*5+j*7+int(s.Frame))%512)
			}
			c.Fg ^= uint32((x + y + int(s.Frame)) & 0x0f)
			c.Attr = uint16((int(c.Attr) + x + 1) & 15)
		}
	}
}

type NaiveFrame struct {
	Rows    []NaiveRow
	CursorX int
	CursorY int
}

type NaiveRow struct {
	Version uint64
	Cells   []NaiveCell
}

type NaiveCell struct {
	Codepoint uint32
	Combining []uint32
	Fg        uint32
	Bg        uint32
	Attr      uint16
}

func NaiveUpdate(s *Screen) *NaiveFrame {
	return NaiveUpdateWithScratch(s, 0)
}

func NaiveUpdateWithScratch(s *Screen, scratchCap int) *NaiveFrame {
	out := &NaiveFrame{
		Rows:    make([]NaiveRow, len(s.Rows)),
		CursorX: s.CursorX,
		CursorY: s.CursorY,
	}
	for y := range s.Rows {
		src := &s.Rows[y]
		cells := make([]NaiveCell, len(src.Cells))
		for x, c := range src.Cells {
			n := int(c.CombLen)
			capacity := n
			if scratchCap > capacity {
				capacity = scratchCap
			}
			combining := make([]uint32, n, capacity)
			copy(combining, c.Combining[:c.CombLen])
			cells[x] = NaiveCell{
				Codepoint: c.Codepoint,
				Combining: combining,
				Fg:        c.Fg,
				Bg:        c.Bg,
				Attr:      c.Attr,
			}
		}
		out.Rows[y] = NaiveRow{
			Version: src.Version,
			Cells:   cells,
		}
	}
	return out
}

type DirtyKind uint8

const (
	DirtyFalse DirtyKind = iota
	DirtyPartial
	DirtyFull
)

type RenderState struct {
	Rows        []StateRow
	rowVersions []uint64
	dirtyRows   []int
	RowsLen     int
	Cols        int
	Dirty       DirtyKind
	CursorX     int
	CursorY     int
}

type StateRow struct {
	Version      uint64
	Cells        []StateCell
	GraphemePool []uint32
	Dirty        bool
}

type StateCell struct {
	Codepoint   uint32
	CombineFrom uint32
	CombineLen  uint16
	Fg          uint32
	Bg          uint32
	Attr        uint16
}

func (st *RenderState) Update(s *Screen) {
	rows := len(s.Rows)
	cols := s.Cols
	full := st.RowsLen != rows || st.Cols != cols || len(st.Rows) != rows
	if full {
		if cap(st.Rows) < rows {
			st.Rows = make([]StateRow, rows)
		} else {
			st.Rows = st.Rows[:rows]
		}
		if cap(st.rowVersions) < rows {
			st.rowVersions = make([]uint64, rows)
		} else {
			st.rowVersions = st.rowVersions[:rows]
			for i := range st.rowVersions {
				st.rowVersions[i] = 0
			}
		}
		if cap(st.dirtyRows) < rows {
			st.dirtyRows = make([]int, 0, rows)
		} else {
			st.dirtyRows = st.dirtyRows[:0]
		}
		st.RowsLen = rows
		st.Cols = cols
	} else {
		for _, y := range st.dirtyRows {
			st.Rows[y].Dirty = false
		}
		st.dirtyRows = st.dirtyRows[:0]
	}

	st.CursorX = s.CursorX
	st.CursorY = s.CursorY
	anyDirty := false
	for y := 0; y < rows; y++ {
		src := &s.Rows[y]
		if !full && st.rowVersions[y] == src.Version {
			continue
		}
		anyDirty = true
		st.rowVersions[y] = src.Version

		dst := &st.Rows[y]
		dst.Version = src.Version
		dst.Dirty = true
		st.dirtyRows = append(st.dirtyRows, y)
		if cap(dst.Cells) < cols {
			dst.Cells = make([]StateCell, cols)
		} else {
			dst.Cells = dst.Cells[:cols]
		}
		needPool := cols * MaxClusterLen
		if cap(dst.GraphemePool) < needPool {
			dst.GraphemePool = make([]uint32, 0, needPool)
		} else {
			dst.GraphemePool = dst.GraphemePool[:0]
		}

		pool := dst.GraphemePool[:needPool]
		poolLen := 0
		for x, c := range src.Cells {
			start := poolLen
			switch c.CombLen {
			case 0:
			case 1:
				pool[poolLen] = c.Combining[0]
				poolLen++
			case 2:
				pool[poolLen] = c.Combining[0]
				pool[poolLen+1] = c.Combining[1]
				poolLen += 2
			default:
				poolLen += copy(pool[poolLen:], c.Combining[:c.CombLen])
			}
			dst.Cells[x] = StateCell{
				Codepoint:   c.Codepoint,
				CombineFrom: uint32(start),
				CombineLen:  c.CombLen,
				Fg:          c.Fg,
				Bg:          c.Bg,
				Attr:        c.Attr,
			}
		}
		dst.GraphemePool = pool[:poolLen]
	}

	switch {
	case full:
		st.Dirty = DirtyFull
	case anyDirty:
		st.Dirty = DirtyPartial
	default:
		st.Dirty = DirtyFalse
	}
}

func (f *NaiveFrame) Hash() uint64 {
	h := uint64(1469598103934665603)
	h = mix(h, uint64(f.CursorX))
	h = mix(h, uint64(f.CursorY))
	for _, row := range f.Rows {
		h = mix(h, row.Version)
		for _, cell := range row.Cells {
			h = mix(h, uint64(cell.Codepoint))
			h = mix(h, uint64(cell.Fg))
			h = mix(h, uint64(cell.Bg))
			h = mix(h, uint64(cell.Attr))
			h = mix(h, uint64(len(cell.Combining)))
			for _, cp := range cell.Combining {
				h = mix(h, uint64(cp))
			}
		}
	}
	return h
}

func (st *RenderState) Hash() uint64 {
	h := uint64(1469598103934665603)
	h = mix(h, uint64(st.CursorX))
	h = mix(h, uint64(st.CursorY))
	for _, row := range st.Rows {
		h = mix(h, row.Version)
		for _, cell := range row.Cells {
			h = mix(h, uint64(cell.Codepoint))
			h = mix(h, uint64(cell.Fg))
			h = mix(h, uint64(cell.Bg))
			h = mix(h, uint64(cell.Attr))
			h = mix(h, uint64(cell.CombineLen))
			start := int(cell.CombineFrom)
			end := start + int(cell.CombineLen)
			for _, cp := range row.GraphemePool[start:end] {
				h = mix(h, uint64(cp))
			}
		}
	}
	return h
}

func mix(h, v uint64) uint64 {
	h ^= v + 0x9e3779b97f4a7c15 + (h << 6) + (h >> 2)
	return h
}
