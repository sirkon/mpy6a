# Глоссарий.

RPC-ручки (т.е. методы сервисов) делятся на следующие категории:

## Унарный.

Он же UU от Unary-Unary, он же RR от Request-Response.

Здесь в реализации мы получаем запрос от клиента и отдаем ему ответ, после чего взаимодействие заканчивается.

```mermaid
sequenceDiagram
    actor A as Client
    A ->> Service: выполни мне запрос с данными Request.
    Service ->> A: выполнил, вот тебе ответ в Response.
```

## SU

От Stream-Unary.

Здесь реализация полностью вычитывает данные отдаваемые в стриме клиентом и затем отвечает одним запросом.

```mermaid
sequenceDiagram
    actor A as Client
    A ->> Service: данные запроса Request1
    A ->> Service: данные запроса Request2
    Service ->> A: ответ Response
```

## US

От Unary-Stream.

Здесь реализация получает один запрос, но данные отдает постепенно.

```mermaid
sequenceDiagram
    actor A as Client
    A ->> Service: данные запроса Request
    Service ->> A: ответ Response1
    Service ->> A: ответ Response2
```

## Бистрим.

Бистрим допускает два способа взаимодействия: **полудуплексное** и **полнодуплексное**.

### Полудуплексный бистрим.

Это, фактически, последовательность унарных запросов. Клиент шлет данные и строго ожидает ответа от сервиса на
эти данные. После чего переходит к следующему запросу. Это не обязательно так. Например, если логика "подписочная",
то клиент ожидает данные от сервиса и затем обязательно отвечает на них. Это тоже полудуплексный тип
взаимодействия.

Здесь иллюстрируется первый вариант. Второй аналогичен, просто Request и Response меняются местами.

```mermaid
sequenceDiagram
    actor A as Client
    A ->> Service: данные запроса Request1
    Service ->> A: ответ Response1
    A ->> Service: данные запроса Request2
    Service ->> A: ответ Response2
    A ->> Service: данные запроса Request3
    Service ->> A: ответ Response3
```

### Полнодуплексный бистрим.

В этом типе бистримов нет вообще никакого порядка взаимодействия. Запросы ответы вообще не обязаны друг-другу
соответствовать. Например, возможно такое:

```mermaid
sequenceDiagram
    actor A as Client
    A ->> Service: данные запроса Request1
    Service ->> A: ответ Response1
    Service ->> A: ответ Response2
    Service ->> A: ответ Response3
    A ->> Service: данные запроса Request2
    A ->> Service: данные запроса Request3
    Service ->> A: ответ Response4
```