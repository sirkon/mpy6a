package state

import "github.com/sirkon/mpy6a/internal/types"

type (
	// savedSessionsSourceDescriptor описания источников
	// сохранённых сессий удовлетворяют этому интерфейсу.
	savedSessionsSourceDescriptor interface {
		isSavedSessionsSourceDescriptor()
	}

	// savedSessionsSourceDescriptorSnapshot указывает
	// на слепок созданный для данного индекса состояния.
	savedSessionsSourceDescriptorSnapshot struct {
		isSavedSessionsSourceDescriptorType

		StateID types.Index
	}

	// savedSessionsSourceDescriptorMerged указывает
	// на слияния произведённое для данного индекса
	// состояния.
	savedSessionsSourceDescriptorMerged struct {
		isSavedSessionsSourceDescriptorType

		StateID types.Index
	}

	// savedSessionsSourceDescriptorMemory указывает
	// на память.
	savedSessionsSourceDescriptorMemory struct {
		isSavedSessionsSourceDescriptorType
	}

	// savedSessionsSourceDescriptorFixedTimeout указывает
	// на файл с сохранёнными сессиями с данной величиной
	// ожидания перед повтором созданный при данном значении
	// индекса состояния.
	savedSessionsSourceDescriptorFixedTimeout struct {
		isSavedSessionsSourceDescriptorType

		StateID types.Index
		Timeout uint32
	}
)

type isSavedSessionsSourceDescriptorType struct{}

func (*isSavedSessionsSourceDescriptorType) isSavedSessionsSourceDescriptor() {}
