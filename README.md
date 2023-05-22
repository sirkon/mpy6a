# mpy6a

Или просто **труба**. Это распределённый *WAL*, т.е. **W**rite **A**head **L**og, т.е. сущность предоставляющая
функциональность распределённого лога с группировкой записей по **сессиям**, с возможностью получить записанные 
данные для т.н. **незавершённых сессий** (и, опираясь на данные, завершить сессии).

Труба является одним из субъектов взаимодействия:

* Сама труба.
* Клиентские приложения, создающие сессии и работающие с ними.
* Сущности, получающие незавершённые сессии. В сущности, это те же самые клиентские приложения реализующие
  через стандартизованный протокол. Эти сущности не подключаются к трубе, это труба подключается к ним.

Клиентам предоставляются следующие ручки:

```go
// Tpy6a клиент вначале создаёт сессию, чтобы работать с ней.
type Tpy6a interface{
	// New создаёт новую сессию с указанным родом клиента.
	// Род клиента нужен чтобы потом, если потребуется обработка
	// незавершённых сессий, выбирать правильный обработчик.
	New(clientKind uint32) (Session, error)
}

// Session функциональность работы с сессией.
type Session interface{
	// ID индекс сессии.
	ID() Index
	// Append добавить очередной кусок данных в сессию
	Append(record []byte) error
	// Replace очистить список накопленных в рамках сессии данных
	// и сразу же добавить туда новую запись.
	Replace(record []byte) error
	// Delete удаляет сессию, она считается завершённой после этого.
	Delete() error
	// Store закрывает запись в сессию и отправляет её на
    // повторную обработку через указанное число секунд как
	// незавершённую.
	Store(timeout uint32) error
}
```

Тогда как "сущности, получающие незавершённые сессии" получают пару

```go
type RepeatData struct{
	// Records накопленные в рамках сессии данные.
	Records [][]byte
	Session Session
}
```
и далее работают с сессией как обычные клиенты.

## Что это на самом деле.

Строго говоря, это не совсем WAL. Труба – это машина состояний для WAL-а.
От пользователя требуется:

1. Определить и реализовать протокол взаимодействия с клиентами.
2. Определить ручки для восстанавливаемых сессий. Собственно, этот пункт и послужил причиной почему труба не является
   конечным продуктом. Хотя общие рекомендации есть, но всякие аутентификации/авторизации в рамках работы конкретного
   набора (микро)сервисов могут отличаться, поэтому это и отдано на откуп пользователю. 
   Можно было, конечно, реализовать pubsub модель, когда сессии создаются в рамках темы, а для тем имеются подписчики,
   но такой подход вносил бы слишком много энтропии. Например, ситуация когда для какой-то конкретной темы нет
   подписчиков. Подход с автоматической раздачей, когда темы жёстко определены где-то в конфиге, представляется более
   железобетонным и поэтому предпочтительным.

[Глоссарий](docs/glossary.md)
[Поток осуществляения операций](docs/lld/operations_flow.md)
