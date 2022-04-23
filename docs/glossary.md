# Глоссарий.

## Топики.

Топик — это уникальное имя имеющее следующие аттрибуты:

* Интервал времени, это минимальное время по прошествии которого начинается повтор для сессии (см. далее) топика. 
* Максимальное число попыток повторов сессий.

## Сессии.

Сессия это кортеж состоящий из следующих компонентов:

1. Запланированное время следующего повтора.
2. Уникальный идентификатор.
3. Идентификатор состояния, равный состоянию системы в момент когда было совершено последнее изменение бинарных данных 
   сессии. 
4. Топик.
5. Прошедшее число повторов.
6. Бинарные данные.

## Повтор сессии.

Это процесс, в рамках которого подписчик на топик к которому относится данная сессия:

1. Получает бинарные данные сессии.
2. Проводит работу с ними, в процессе могут осуществляться следующие манипуляции:
   * Добавление бинарных данных в конец данных сессии.
   * Очистка данных в сессии — бинарные данные сессии становятся пустыми.
   * Завершение сессии, подписчик может дать указание считать данную сессию выполненной, такая сессии удаляются
     из системы и никогда больше не повторяются.

Внимание: повтор сессии начинается не раньше запланирванного времени повтора, при этом ситуация, когда повтор начался
          с запозданием относительно запланированного времени — штатная.
