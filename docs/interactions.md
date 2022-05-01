# Взаимодействия в системе.

У нас есть:

* Кластер реализующий систему.
* Клиенты работающие с кластером.
* Т.н. "сервис восстановления" реализующий некоторый интерфейс, с помощью методов которого производится повтор сессий.

## Функционирование системы при получении данных от клиентов.

1. Клиент делает запрос к ноде к которой он подключён.
2. Если нода не является лидером, то она проксирует запрос к лидеру. Данный отход от оригинального RAFT — в котором 
   ведомый узел отдаёт отлуп клиенту указывая на текущего лидера — обусловлен желанием воспользоваться механизмом
   балансировки используемого клиентами RPC, чтобы не заморачиваться с ручным шардированием.
3. Лидер принимает запрос, заводит сессию.
4. Происходит взаимодействие клиента с лидером.
5. По результатам сессия либо удаляется, либо сохраняется для повтора позднее.

## Работа для восстановления сессий.

Когда приходит время восстановления сессии

1. Лидер вычитывает сессию в память, что делает её активной.
2. Делает запрос на проигрывание к "сервису восстановления".
3. Идёт взаимодействие с сервисом повторов точно такое же, как и с клиентом.

## Визуальное представление схемы работы

![схема работы](interaction.png)