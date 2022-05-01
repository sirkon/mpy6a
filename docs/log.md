# Работа с логом.

Напомним, что лог хранит операции применяемые к состоянию и конечной целью является приведение внутреннего состояния
ведомых узлов к состоянию лидера.

В отличии от систем хранения общего назначения, нам нет нужды привязываться к оригинальному "глобальному" логу 
операций, т.к. "лог" может быть вычислен в достаточном для цели синхронизации узлов объёме непосредственно из
самих хранимых данных.

Назовём такую возможность логическим логом.

Построение логического лога основано на следующих фактах:

* Некоторые операции в логическом логе становятся "крупнее". Так, скажем, сессия всегда представляется монолитным 
  куском, тогда как её данные могли быть составлены в результате нескольких операций добавления или перезаписи.
* Порядок операций модернизирующих разные сессии не важен, т.к. сессии полностью независимы друг от друга.

Из этих двух соображений вытекает, что:

* При удалении сессии на лидере нет никакой нужды синхронизировать состояние сессии на последователе до состояния на 
  лидере и затем удалять. Можно тупо удалить все записи "добавить что-то" и оставить одну: удалить.
* Аналогично для файлов с данными сессиями: если он удалён, то не нужно досинхронизировывать файл и затем удалять, 
  нужно удалять сразу.

## Конструирование логического лога.

При его построении мы учитываем что:

* Все хранимые сущности имеют аттрибут "последняя операция изменения".
* Файлы передаются как последовательность

    | Данные файла | Данные контроля состояния файла |
    |--------------|---------------------------------|
  
  Т.е. по достижению конца данных в файле следует передача описания файла.

Далее выполняем действуем по следующему алгоритму:

1. Получаем от последователя описания всех его перманентных данных, т.е. все его текущие дескрипторы файлов.
2. Находим среди них то описание, которые было изменено позже остальных, обозначим его пару последнего изменения 
   (срок, индекс) как T.
3. Далее строим последовательность состоящую из всех текущих элементов, дескрипторов файлов и активных
   сессий, изменившихся после T и упорядоченную по индексу последнего изменения.
4. Берём первый элемент построенного контейнера и учитываем т.н. "пост-шаг" — это действие которое выполняется после 
   подтверждения вычитки элемента лога.
   * Если никаких данных в контейнере не осталось, то клиент синхронизирован.
   * Если это дескриптор файла.
     * Если все бинарные данные файла у клиента есть, то, получается, записью будет дескриптор файла.
       Пост-шагом становится операция 
       "удаление первого элемента контейнера и установить T в последнее время изменения файла".
     * Если каких-то бинарных данных нет, то записью будет сессия из этого файла.
       Пост-шагом становится операция 
       "сдвиг позиции чтения из файла на размер сессии и установить T в последнее время изменения данной сессии".
   * Если это сессия, то она сама становится записью логического лога. Пост-шагом становится 
     "удаление первого элемента контейнера и установить T в последнее время изменения данной сессии".
5. После применения элемента лога к состоянию применяем пост-шаг.
6. Повторяем с пункта 4.

Но это не все шаги: данные могут изменяться, вызывая изменения и логического лога в том числе, а в общем случае этот
лог обрабатывается не один шаг, мутации данных крайне вероятны в таком случае.

При изменениях данных он преобразуется следующим образом:

* Если происходит создание файла, то его дескриптор помещается в конец контейнера. 
* Если происходит изменение (не удаление) файла, то дескриптор файла перемещается или помещается (если его нет) в 
  конец контейнера.
* Если происходит удаление файла
  * Если файл был создан после T, то из контейнера просто удаляется дескриптор этого файла.
  * Иначе из контейнера удаляется дескриптор файла, а в конец контейнера, с текущим индексом (срок, индекс в сроке),
    помещается операция "удалить файл"
* Если происходит создание сессии, то её содержимое помещается в конец контейнера с текущим индексом.
* Если происходит мутация сессии перемещается (добавляется, если её нет в контейнере) в конец контейнера.
* Если происходит удаление сессии
  * Если она была создана после срока T, то сессия просто удаляется из контейнера
  * Иначе происходит удаление из контейнера, а в конец контейнера, с текущим индексом, помещается операция 
    "удалить сессию". 

## Выбор структуры данных для контейнера.

Кажется, что наилучшим способом работы будет двусвязный список, т.к. для работы требуется единственное упорядочивание
в самом начале, а затем порядок поддерживается самих ходом проведения операции.

При этом есть операции 

* "получить первый элемент"
* "добавить в конец"

Недостатком будет необходимость вести дополнительные индексы "узлы файлов" и "узлы сессий" для быстрого нахождения 
нужных.

Как альтернативу можно рассмотреть самобалансирующиеся бинарные деревья, которые в среднем уступают в эффективности
вставки и добавления, но зато не требуют дополнительных индексов для поиска элемента — ключом здесь будет "предыдущее
значение индекса (срок, индекс в сроке)" данной сущности перед её изменением.

## Означает ли наличие логического лога отказ от низкоуровневого.

Нет, не означает. При штатной работе низкоуровневый лог выходит намного дешевле с точки зрения потребляемых ресурсов.
Но за счёт существования логического можно отказаться от персистентности в низкоуровневом, храня в кольцевом буфере, 
в памяти, только ограниченное количество событий. В случае если последователь отстал катастрофически, больше чем на 
длину кольцевого буфера, то он переходит в режим "синхронизации", в котором используется логический лог. 
В штатном режиме же данные реплицируются используя события из низкоуровневого буфера.