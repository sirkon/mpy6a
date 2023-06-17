package sourceio

import (
	"encoding/binary"
	"io"

	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/mpio"
)

// MergeSources сливает два источника в данный приёмник.
// Нам необходимо хранить в точности тот порядок записей, который
// используется при вычитке, т.е. сохранённые сессии из более
// раннего источника с одинаковым временем повтора имеют приоритет.
// Источники при слиянии должны сохранять порядок старшинства,
// т.е. источник созданный раннее должен быть в переменной a,
// а не наоборот.
func MergeSources(
	dst *Writer,
	a mpio.DataReader,
	b mpio.DataReader,
) error {
	aIt := rawIterator{src: a}
	bIt := rawIterator{src: b}

	var aRepeat uint64
	var bRepeat uint64
	if aIt.Next() {
		aRepeat, _ = aIt.Repeat()
	}
	if bIt.Next() {
		bRepeat, _ = bIt.Repeat()
	}

	for aRepeat > 0 && bRepeat > 0 {
		if aRepeat <= bRepeat {
			aDone, err := saveContentUntil(dst, &aIt, bRepeat+1)
			if err != nil {
				return errors.Wrap(err, "save content from a before events from b").
					Uint64("b-repeat", bRepeat+1)
			}

			if aDone {
				aRepeat = 0
			} else {
				aRepeat, _ = aIt.Repeat()
			}
		}

		// Содержимое b у нас ещё не исчерпалось по-определению, при этом все
		// события могущие предшествовать им уже были вычитаны из a. Поэтому
		// мы просто копируем подходящее содержимое из b в приёмник до первого
		// элемента в a. Ну, или до конца, если был вычитан, т.е. aRepeat = 0.
		bDone, err := saveContentUntil(dst, &bIt, aRepeat)
		if err != nil {
			return errors.Wrap(err, "save content from b before events from a").
				Uint64("a-repeat", aRepeat)
		}

		if bDone {
			bRepeat = 0
		} else {
			bRepeat, _ = bIt.Repeat()
		}
	}

	if aRepeat > 0 {
		if _, err := saveContentUntil(dst, &aIt, 0); err != nil {
			return errors.Wrap(err, "save content from a after b was drained")
		}
	} else if bRepeat > 0 {
		if _, err := saveContentUntil(dst, &bIt, 0); err != nil {
			return errors.Wrap(err, "save content from b after a was drained")
		}
	}

	if err := dst.Flush(); err != nil {
		return errors.Wrap(err, "flush collected data")
	}

	return nil
}

// saveContentUntil вычитка и сохранение содержимого итератора у которого
// была сделана предварительная вычитка. Копируется содержимое вплоть
// до сохранённого события на время until, не включая его.
//
// Предварительность вычитки означает, что на итераторе уже был вызван Next
// и необходимо вначале сохранить первое вычитанное значение и затем уже
// переходить к последующим чтениям.
func saveContentUntil(dst *Writer, src *rawIterator, until uint64) (done bool, err error) {
	repeat, data := src.Repeat()
	if err := dst.SaveRawSession(repeat, data); err != nil {
		return false, errors.Wrap(err, "save head session").
			Pfx("session").
			Uint64("repeat-time", repeat).
			Int("raw-len", len(data))
	}

	for src.Next() {
		repeat, data = src.Repeat()
		if until > 0 && repeat >= until {
			return false, nil
		}
		if err := dst.SaveRawSession(repeat, data); err != nil {
			return false, errors.Wrap(err, "save session").
				Pfx("session").
				Uint64("repeat-time", repeat).
				Int("raw-len", len(data))
		}
	}

	if err := src.Err(); err != nil {
		return false, errors.Wrap(err, "iterate over source")
	}

	return true, nil
}

type rawIterator struct {
	src  mpio.DataReader
	err  error
	item repeatIteratorItem
}

// Next смотрит, есть ли следующий элемент и вычитывает, если есть.
func (it *rawIterator) Next() bool {
	if it.err != nil {
		return false
	}

	var buf [8]byte
	if _, err := io.ReadFull(it.src, buf[:]); err != nil {
		it.err = errors.Wrap(err, "read repeat time")
		return false
	}
	it.item.repeat = binary.LittleEndian.Uint64(buf[:])

	length, err := binary.ReadUvarint(it.src)
	if err != nil {
		if err == io.EOF {
			err = io.ErrUnexpectedEOF
		}
		it.err = errors.Wrap(err, "read session data length")
		return false
	}

	if length > uint64(cap(it.item.data)) {
		it.item.data = make([]byte, length)
	} else {
		it.item.data = it.item.data[:length]
	}

	if _, err := io.ReadFull(it.src, it.item.data); err != nil {
		if err == io.EOF {
			err = io.ErrUnexpectedEOF
		}
		it.err = errors.Wrap(err, "read session data")
		return false
	}

	return true
}

// Repeat выдача вычитанных данных.
func (it *rawIterator) Repeat() (repeat uint64, data []byte) {
	return it.item.repeat, it.item.data
}

func (it *rawIterator) Err() error {
	if it.err == nil {
		return nil
	}

	if errors.Is(it.err, io.EOF) {
		return nil
	}

	return it.err
}

type repeatIteratorItem struct {
	repeat uint64
	data   []byte
}
