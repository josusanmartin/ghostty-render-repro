package renderbench

import (
	"runtime"
	"testing"
)

var sinkHash uint64
var sinkFrame *NaiveFrame

const benchRows = 1000
const benchCols = 160
const benchDirtyRows = 4
const auditClusterLen = DefaultClusterLen
const auditScratchCap = 512

func TestOptimizedMatchesNaiveAfterUpdates(t *testing.T) {
	s := NewScreenWithCluster(80, 120, 7)
	var st RenderState
	for frame := 0; frame < 40; frame++ {
		AdvanceFrame(s, 5)
		naive := NaiveUpdate(s)
		st.Update(s)
		if got, want := st.Hash(), naive.Hash(); got != want {
			t.Fatalf("frame %d hash mismatch: got %x want %x", frame, got, want)
		}
	}
}

func TestOptimizedSteadyStateAllocs(t *testing.T) {
	s := NewScreenWithCluster(benchRows, benchCols, auditClusterLen)
	var st RenderState
	st.Update(s)
	allocs := testing.AllocsPerRun(100, func() {
		AdvanceFrame(s, benchDirtyRows)
		st.Update(s)
		sinkHash ^= uint64(st.Dirty) + uint64(st.CursorX)
	})
	if allocs != 0 {
		t.Fatalf("steady optimized update allocated: %.3f allocs/run", allocs)
	}
}

func BenchmarkNaiveClone(b *testing.B) {
	s := NewScreenWithCluster(benchRows, benchCols, DefaultClusterLen)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		AdvanceFrame(s, benchDirtyRows)
		frame := NaiveUpdate(s)
		sinkHash ^= uint64(len(frame.Rows))
		sinkFrame = frame
	}
}

func BenchmarkNaiveCloneAudit88ms(b *testing.B) {
	s := NewScreenWithCluster(benchRows, benchCols, auditClusterLen)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		AdvanceFrame(s, benchDirtyRows)
		frame := NaiveUpdateWithScratch(s, auditScratchCap)
		sinkHash ^= uint64(len(frame.Rows))
		sinkFrame = frame
	}
}

func BenchmarkNaiveCloneAudit88msRenderOnly(b *testing.B) {
	s := NewScreenWithCluster(benchRows, benchCols, auditClusterLen)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		b.StopTimer()
		AdvanceFrame(s, benchDirtyRows)
		b.StartTimer()
		frame := NaiveUpdateWithScratch(s, auditScratchCap)
		sinkHash ^= uint64(len(frame.Rows))
		sinkFrame = frame
	}
}

func BenchmarkOptimizedSteady(b *testing.B) {
	s := NewScreenWithCluster(benchRows, benchCols, DefaultClusterLen)
	var st RenderState
	st.Update(s)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		AdvanceFrame(s, benchDirtyRows)
		st.Update(s)
		sinkHash ^= uint64(st.CursorX) + uint64(st.Dirty)
	}
	runtime.KeepAlive(&st)
}

func BenchmarkOptimizedSteadyAudit88ms(b *testing.B) {
	s := NewScreenWithCluster(benchRows, benchCols, auditClusterLen)
	var st RenderState
	st.Update(s)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		AdvanceFrame(s, benchDirtyRows)
		st.Update(s)
		sinkHash ^= uint64(st.CursorX) + uint64(st.Dirty)
	}
	runtime.KeepAlive(&st)
}

func BenchmarkOptimizedSteadyAudit88msRenderOnly(b *testing.B) {
	s := NewScreenWithCluster(benchRows, benchCols, auditClusterLen)
	var st RenderState
	st.Update(s)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		b.StopTimer()
		AdvanceFrame(s, benchDirtyRows)
		b.StartTimer()
		st.Update(s)
		sinkHash ^= uint64(st.CursorX) + uint64(st.Dirty)
	}
	runtime.KeepAlive(&st)
}

func BenchmarkAdvanceFrameAudit88ms(b *testing.B) {
	s := NewScreenWithCluster(benchRows, benchCols, auditClusterLen)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		AdvanceFrame(s, benchDirtyRows)
	}
}

func BenchmarkOptimizedFullRedrawWarm(b *testing.B) {
	s := NewScreenWithCluster(benchRows, benchCols, DefaultClusterLen)
	var st RenderState
	st.Update(s)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		AdvanceFrame(s, len(s.Rows))
		st.Update(s)
		sinkHash ^= uint64(st.CursorY) + uint64(st.Dirty)
	}
	runtime.KeepAlive(&st)
}

func BenchmarkOptimizedFullRedrawWarmAudit88ms(b *testing.B) {
	s := NewScreenWithCluster(benchRows, benchCols, auditClusterLen)
	var st RenderState
	st.Update(s)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		AdvanceFrame(s, len(s.Rows))
		st.Update(s)
		sinkHash ^= uint64(st.CursorY) + uint64(st.Dirty)
	}
	runtime.KeepAlive(&st)
}
