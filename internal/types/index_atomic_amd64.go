package types

func newIndexAtomic() IndexAtomic {
	return newIndexAtomicAlign(16)
}
