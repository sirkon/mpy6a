# Операторы.

Для понимания контекста нужно прочесть материал из [описания проводки задач операторов](./operations_flow.md).

Оператор – это сущность проводящая операции с состоянием посредством постановки задач. Она, через несложную прослойку,
обеспечивает взаимодействие со сторонними сущностями находящимися за пределами системы.

Операторы классифицируются по методу их инициации:

* Клиентский оператор создаётся в процессе обработки запроса от внешнего клиента. Его первой операцией
  всегда является создание сессии:
  ```
  NewSession → [Append|Reset]* → Delete|Store. 
  ```
  Т.е. вначале выполняетзся NewSession создающий сессию, затем последовательность `Append` или, намного реже, 
  `Reset`, а в самом конце идёт единственный `Delete` или `Store`.

* Оператор повтора создаётся для повтора сессий. Оператор такого вида выполняет операции только второго и третьего 
  этапов если сравнивать с клиентским:
  ```
  [Append|Reset]* → Delete|Store.
  ```
  
Кроме этого различий между ними не имеется.

## Детали реализации.

Оператору выдаётся канал операций и функция `req` имеющая тип:

```go
// Такая функция используется для получения дальнейших запросов от 
// управляющей сущности.
// 
// - next указывает на ожидание следующих запросов.
// - err сообщает о произошедших ошибках.
type Response func(next bool, err error) (RequestData, error)
```

- Смысл канала операций понятен: туда улетают задачи, которые ставит данный оператор.
- А функция `req` нужна для получения запросов от управляющего.

А сейчас важный вопрос: как оператор понимает, что задача выполнена?

Очень просто, на самом деле. Задача имеет ссылку на лок-объект, который определён у оператора. 

1. Перед отправкой задачи в канал операций локер блокируется самим оператором.
2. После отправки оператор ещё раз пытается взять локер.
3. Задача, в конце жизненного цикла, снимает блок. Это производится в функциях `Apply` и `ReportError`.
4. Оператор, наконец, берёт локер и считывает нужную информацию, которая сохраняется в недрах задачи.

Это почти нормально, т.к. оператор является частью системы и должен обеспечить проводку невзирая на состояние
внешнего управляющего. Т.е., например, он не должен зависеть от контекста управляющего.

Почти, потому что при останове системы могут подвеситься горутины сидящие в ожидании разблокировки локеров.
Чтобы решить эту проблему, при начале останова запускается "чистильщик". Он вычитывает канал операций
и канал задач, вызывая `ReportError` на каждой задаче из тамошних сущностей. Кривовато, но всяко лучше, чем создавать
канал для каждого оператора, выполняя подмножество своей функциональности вполне реализуемое мютексом.

## Примерный вид определения задачи

```go
package operator

import (
  "sync"

  "github.com/sirkon/mpy6a/internal/types"
)

type OperatorTask struct {
  session *types.Session
  err     bool
  oplock  sync.Locker

  task TaskDetails
}

type taskDetailsCode int

const (
  taskDetailsCodeNew = iota + 1
  taskDetailsCodeAppend
  taskDetailsCodeReplace
  taskDetailsCodeDelete
  taskDetailsCodeStore

  taskDetailsMutate = taskDetailsCodeAppend | taskDetailsCodeReplace
  taskDetailsFinish = taskDetailsCodeDelete | taskDetailsCodeStore
)

type TaskDetails struct {
  code    taskDetailsCode
  theme   uint32
  data    []byte
  time    uint64
}

```

## Примерный вид реализации оператора

```go
package operator

import (
  "sync"

  "github.com/sirkon/errors"
)

type operatorState int

const (
  // operatorStateNew – начальное состояние клиентского оператора
  operatorStateNew operatorState = 1 << iota

  // operatorStateMutate – состояние при котором возможны операции Append/Replace/Delete/Store.
  operatorStateMutate

  // operatorStateFinish – состояние после выполнения Delete/Store. Никакие задачи после этого не ставятся.
  operatorStateFinish
)

// Operator определение оператора.
type Operator struct {
  state operatorState
  lock  sync.Locker
  ops   chan<- OperatorTask
  req   Response
}

// Execute запуск оператора.
func (o *Operator) Execute() error {
  task := OperatorTask{
    oplock: &o.lock,
  }
  for o.state != operatorStateFinish {
    req, err := o.req(true, nil)
    if err != nil {
      return errors.Wrap(err, "request task data")
    }

    switch o.state {
    case operatorStateNew:
      // С точки зрения управляющего нет операции New, т.к. для него
      // сессия создана когда он успешно начал запрос. Это мы первый его
      // Append трактуем как NewSession.
      td, err := o.taskDetails(req, taskDetailsAppend)
      if err != nil {
        return err
      }

      td.code = taskDetailsCodeNew

    case operatorStateMutate:
      if td, err = o.taskDetails(req, taskDetailsMutate|taskDetailsFinish); err != nil {
        return err
      }
      if td.code&taskDetailsFinish != 0 {
        o.state = operatorStateFinish
      }

    default:
      return errors.New("unexpected operator state detected").Int("unexpected-operator-state", o.state)
    }

    // Детали задачи успешно проверены и установлены в соотв. с пожеланиями управляющего.
    // Добавляем их в задачу, а задачу добавляем в очередь операций.
    task.task = td
    o.lock.Lock()
    o.ops <- o
	o.lock.Lock()

    if task.err {
      return mperrs.InternalError
    }
  }

  return nil
}

```








