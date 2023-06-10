# Хранение и использование данных сохранённых сессий.

## Какие свойства должно обеспечивать хранилище.

1. Сохранение сессии должно иметь предсказуемую сложность исполнения.
2. Нахождение сессии для повтора должно быть достаточно быстрым.

Пункт номер 2 является менее приоритетным, поскольку гарантии исполнения близкие к абсолютным
в рамках сетевой инфраструктуры невозможны в принципе.

## Предлагаемый вариант хранилища.

Предлагается использовать подход [LSM](https://ru.wikipedia.org/wiki/LSM-дерево) без индекса ключей – он не нужен,
т.к. нет потребности доставать произвольную сессию, они нам нужны только тогда, когда приходит время их повтора.

Т.е. для хранения сохранённых сессий используются:

- Упорядоченные структуры в памяти, под это хорошо подходят различные варианты сбалансированных деревьев.
- Файлы со следующей структурой:

  | `repeat1` | `len1` | `data1` | `repeat2` | `len2` | `data2` | ... |
  |-----------|--------|---------|:----------|:-------|:--------|:----|

  Где

  | Поле      | Роль поля                          |
  |-----------|------------------------------------|
  | `repeatN` | Время повтора в секундах задачи N. |
  | `lenN`    | Длина бинарных данных задачи N.    |
  | `dataN`   | Бинарные данные задачи N.          |

  И здесь `repeat1 ≤ repeat2 ≤ repeat3 ≤ …`, т.е. записи в файле упорядочены по времени повтора.

Как принято для LSM, данные вначале скидываются в упорядоченные структуры данных, а затем, когда их объём превосходит
пороговый, сбрасываются в файл с вышеописанной структурой.

Как и в стандартном LSM-подходе, разные файлы могут объединяться время от времени, чтобы уменьшалось общее количество
используемых файлов.

### Оценка соответствия этого хранилища требуемым свойствам.

- Сложность сохранения сессии равна сложности вставки в сбалансированное дерево. Т.е. она не превосходит O(N×log N),
  где N – ограничение на количество хранимых в памяти сохранённых сессий. Это число фиксировано, поэтому сложность
  сохранения является константной величиной.
- Сложность поиска складывается из сложности вычитки данных из файлов, вычитки данных из памяти и поиска "наименьшего"
  элемента среди вычитанных. Рассмотрим покомпонентно:
    - Стоимость вычитки из неопределённого количества файлов оценим отдельно.
    - Стоимость вычитки из памяти оценивается как то же самое O(N×log N), т.к. кроме чтения нужно и удаление, которое
      ровно столько и весит (больше, чем поиск старшей записи). Т.е. это фиксированная сложность.
    - Стоимость поиска ближайшего повтора среди всех источников рассмотрим отдельно.

#### Стоимость вычитки с неопределённым количеством файлов.

Здесь и далее **фрагментацией** будем называть количество файлов. **Фрагментацией(ΔT)** будем называть количество
файлов, повторы всех сессий которых происходят до момента "текущее время" + ΔT.

Если бы файлы не сливались, то стоимость вычитки из них равнялась бы стоимости вычитки из одного файла – потому что
одна сессия читается ровно один раз. Когда в дело вмешивается сливатель сшивающий файлы, то количество прочтений
увеличивается на одно за каждую процедуру слияния – но в этом случае нагрузка размазывается по времени, поскольку
сливать файлы, сессии из которых готовятся к повтору в ближайшее время, несколько неразумно.

В итоге получаем, что на практике стоимость вычитки с неопределённым числом файлов примерно равна стоимости вычитки
одного файла. Но с одним жирным **НО**: если распределение времён повторов каждого конкретного файла не равномерное
и имеет такие пики, которые не совпадают с пиками других файлов. В этом случае мы получаем набор сильно 
последовательных чтений, что действительно будет делать многофайловое чтение близким по эффективности к однофайловому.
В ином случае степень последовательности будет определяться размером буфера чтения каждого файла.

#### Стоимость поиска ближайшего повтора.

Есть O(M), где M - число источников. При этом не забываем, что один источник может иметь несколько сессий с одинаковым
временем повтора и они в приоритете по сравнению с сессиями из следующих источников.

### Представление в памяти.

Просто сбалансированное дерево, красно-чёрное например.


### Итераторы по источникам сохранённых сессий.

Интерфейс итератора по источнику повторов выглядит как

```go
type StoredSessionsIterator interface{
    // Next проверка, есть ли следующая запись повтора.
    Next() bool
    
    // RepeatData данные повтора сессии. Возвращает repeatAt
    // время повтора сессии в секундах и данные сессии.
    RepeatData() (repeatAt uint64, session *types.Session)
    
    // Commit подтверждение вычитки. Без вызова этого метода
    // следующий Next возвратит неуспех.
    Commit()
    
    // Err сообщает, является ли окончание итерации следствием ошибки.
    Err() error
    
    // Close закрытие итератора – необходимо для итераторов по файлам.
    // Итератор по дереву, понятно, будет поддерживать этот метод
    // чисто символически.
    Close() error
}
```

Список таких итераторов не является статическим и может меняться:

- Итератор, который пробежал весь файл с повторами удаляется из списка.
- При сбросе содержимого памяти на диск итератор по соотв. файлу добавляется в конец списка.


> Таким образом, набор итераторов проще всего хранить в контейнере типа двусвязный список.<br>
> Любая мутация этого списка, естественно, производится только в момент когда не идёт процесс поиска повторов.

### Когда и как создаются файлы с источниками сессий.

Вначале сессия сохраняется прямо в память. При сохранении очередной сессии, если превышен пороговый объём
хранимых в памяти данных повторов и не идёт других фоновых процессов для повторов, инициируется процесс
сброса данных из памяти в соответствующий файл. **Индексом файла** будет являться индекс операции сохранения сессии.

Процесс создания источника соответствующего дереву в памяти на момент начала длиться какое-то время и дерево
в памяти может претерпевать при этом изменения: удаление сессий для их повтора и добавление новых сессий.

Простейшим вариантом разрешения таких коллизий является простой сброс сборки источника. Но это оооочень такое
себе решение. Если с удалением ещё более-менее терпимо, т.к. объём занимаемой памяти уменьшился и может даже
стал ниже порогового, то с добавлением вообще никуда. Поэтому так делать мы, естественно, не будем и предложим
другой вариант.

Итак, какие логические коллизии могут произойти, если без сброса:

- Во время сохранения какая-то сессия была добавлена в конец контейнера, и мы сохраним и её. Это не говоря
  уже о том, что само итерирование над мутирующим контейнером затея весьма сомнительная.
- Во время сохранения какая-то сессия ушла на повтор уже после момента её сохранения в новый файловый источник.
  А когда источник начнёт проигрываться она вновь будет предоставлена итератором, т.е. произойдёт второй её
  повтор.

Первая коллизия решается сохранением не самого контейнера, а его полного клона, включая и копию списка содержащего
куски данных сессии. Сами куски данных записанных в сессию можно не клонировать – их содержимое никогда не изменяется.

Вторая коллизия решается исходя из факта, что и повтор, и сброс сессий осуществляется в одном и том же порядке.
Это означает, что нам достаточно сохранять длину отправленных на повтор сессий и учесть их после создания, указав
начальную позицию в файле которая бы пропускала записи соответствующие ушедшим на повтор сессиям. Но даже так
есть один тонкий момент:

- Сессия А была сохранена после начала создания источника.
- Сессия А была отправлена на повтор до момента окончания создания источника.

Этой сессии в файле естественно не будет: её нет в оригинальном контейнере. Т.е. нам необходимо пропускать такие 
сессии для вычисления начальной позиции чтения создаваемого источника.

Следующий подход обойдёт вышеописанные коллизии:

1. Создаётся клон контейнера (A), содержимое которого будет сбрасываться на диск.
2. В состоянии, впридачу к контейнеру, создаётся пустой контейнер B.
3. При сохранении сессий они появляются и в старом, и в новом контейнере.
4. При повторе сессии проверяется, нет ли её в новом контейнере:
   - Если её нет, то увеличиваем значение смещения.
   - Если есть, то удаляем и из старого, и из нового контейнеров.
5. После окончания создания заменяем контейнер A на B, вторичный контейнер делаем неактивным и добавляем
   в конец списка итераторов новый – это будет итератор над только что созданным файлом, у которого начальная
   позиция чтения равна посчитанному значению. Вполне может быть и так, что к моменту создания эта позиция
   будет совпадать с длиной созданного файла. В таком случае итератор не добавляется, а контейнер B просто удаляется.

### Когда объединяются файлы с повторами.

В фоне постоянно висит процесс периодически проверяющий количество разных источников. Если их больше чем нужно,
то в очередь добавляется операция процесса объединения, который создаёт копии итераторов (файл, смещение) и проводит 
в фоне операцию слияния. При этом, если в оригинальных итераторах происходит вычитка сессии для повтора, то длина 
вычитанных данных доводится до процесса производящего слияние.

Аналогично процессу создания источника, это значение будет учтено при расчёте позиции начального чтения в файле
объединения.

Когда слияние проведено физически, итератор над слитым файлом должен быть добавлен в состояние, а старые итераторы
удалены.

### Индексы файлов-источников.

Для файла содержащего копию дерева индекс подбирается очень просто: это индекс операции выведшей контейнер за барьер.
А вот для операции слияния всё "немного" сложнее, т.к. она порождается фоновым процессом и какой у неё индекс
совершенно непонятно. Но, к счастью, подход имеется: процесс запускается через очередь выполнения операций и индексом
берут индекс предыдущей операции. Для этого введём следующую условность: если возвращаемые операцией кодированные
данные – пустые, то ни отправки, ни сохранения этой операции в лог не будет. Но будет применение её к контексту,
вследствие чего мы будем знать предыдущий индекс состояния. Который и будем использовать для создаваемых файлов.

### Коллизии процессов использующих итераторы и объекты скрытые за ними.

Их нет, т.к. все операции могущие вызвать коллизию:

- Итерирование по источникам и их чтение.
- Запись в контейнер.
- Копирование контейнера.

Изолированы рамками операций – все они осуществляются в рамках своих операций. Остальные действия производятся
исключительно со "своими", локальными данными.