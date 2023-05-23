package tlog

// TestingPrinter wrapper over *testing.T to print data
type TestingPrinter interface {
	Helper()
	Log(a ...any)
	Logf(format string, a ...any)
	Error(a ...any)
	Errorf(format string, a ...any)
}
