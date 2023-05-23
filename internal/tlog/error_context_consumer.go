package tlog

import "github.com/sirkon/mpy6a/internal/errors"

type errorContextConsumer struct {
	vars []contextVar
}

// Bool to satisfy errors.ErrorContextConsumer
func (c *errorContextConsumer) Bool(name string, value bool) {
	c.vars = append(c.vars, contextVar{
		name:  name,
		value: value,
	})
}

// Int to satisfy errors.ErrorContextConsumer
func (c *errorContextConsumer) Int(name string, value int) {
	c.vars = append(c.vars, contextVar{
		name:  name,
		value: value,
	})
}

// Int8 to satisfy errors.ErrorContextConsumer
func (c *errorContextConsumer) Int8(name string, value int8) {
	c.vars = append(c.vars, contextVar{
		name:  name,
		value: value,
	})
}

// Int16 to satisfy errors.ErrorContextConsumer
func (c *errorContextConsumer) Int16(name string, value int16) {
	c.vars = append(c.vars, contextVar{
		name:  name,
		value: value,
	})
}

// Int32 to satisfy errors.ErrorContextConsumer
func (c *errorContextConsumer) Int32(name string, value int32) {
	c.vars = append(c.vars, contextVar{
		name:  name,
		value: value,
	})
}

// Int64 to satisfy errors.ErrorContextConsumer
func (c *errorContextConsumer) Int64(name string, value int64) {
	c.vars = append(c.vars, contextVar{
		name:  name,
		value: value,
	})
}

// Uint to satisfy errors.ErrorContextConsumer
func (c *errorContextConsumer) Uint(name string, value uint) {
	c.vars = append(c.vars, contextVar{
		name:  name,
		value: value,
	})
}

// Uint8 to satisfy errors.ErrorContextConsumer
func (c *errorContextConsumer) Uint8(name string, value uint8) {
	c.vars = append(c.vars, contextVar{
		name:  name,
		value: value,
	})
}

// Uint16 to satisfy errors.ErrorContextConsumer
func (c *errorContextConsumer) Uint16(name string, value uint16) {
	c.vars = append(c.vars, contextVar{
		name:  name,
		value: value,
	})
}

// Uint32 to satisfy errors.ErrorContextConsumer
func (c *errorContextConsumer) Uint32(name string, value uint32) {
	c.vars = append(c.vars, contextVar{
		name:  name,
		value: value,
	})
}

// Uint64 to satisfy errors.ErrorContextConsumer
func (c *errorContextConsumer) Uint64(name string, value uint64) {
	c.vars = append(c.vars, contextVar{
		name:  name,
		value: value,
	})
}

// Float32 to satisfy errors.ErrorContextConsumer
func (c *errorContextConsumer) Float32(name string, value float32) {
	c.vars = append(c.vars, contextVar{
		name:  name,
		value: value,
	})
}

// Float64 to satisfy errors.ErrorContextConsumer
func (c *errorContextConsumer) Float64(name string, value float64) {
	c.vars = append(c.vars, contextVar{
		name:  name,
		value: value,
	})
}

// String to satisfy errors.ErrorContextConsumer
func (c *errorContextConsumer) String(name string, value string) {
	c.vars = append(c.vars, contextVar{
		name:  name,
		value: value,
	})
}

// Any to satisfy errors.ErrorContextConsumer
func (c *errorContextConsumer) Any(name string, value interface{}) {
	c.vars = append(c.vars, contextVar{
		name:  name,
		value: value,
	})
}

type contextVar struct {
	name  string
	value any
}

var _ errors.ErrorContextConsumer = &errorContextConsumer{}
