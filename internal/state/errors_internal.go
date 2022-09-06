package state

import (
	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/types"
)

func errorInternalSessionAlreadyExists(sessionID types.Index) error {
	return errors.New("Session with id matching current state index exists already").
		Stg("existing-Session-id", sessionID)
}

func errorInternalUnknownSession(sessionID types.Index) error {
	return errors.New("Session does not exists").Stg("unknown-Session-id", sessionID)
}

func errorInternalMissingKnownToExistLogFile(name string) error {
	return errors.New("not found a log file known to exist")
}

func errorInternalNoTimeoutSupport(timeout int) error {
	return errors.Newf("no storage found for the timeout").Int("unsupported-timeout", timeout)
}

func errorInternalIncorrectSessionData() error {
	return errors.New("incorrect session data")
}

func errorInternalCorruptedSavedSourceFile(msg string) error {
	return errors.New("corrupted saved sessions file: " + msg)
}

func errorInternalInvalidTermDecoded() error {
	return errors.New("invalid term decoded")
}

func errorInternalMissingSessionToRead(source string) error {
	return errors.New("missing Session in the source").Str("Session-source-name", source)
}
