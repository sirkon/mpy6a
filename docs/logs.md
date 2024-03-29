# Логи слепков.

При создании слепка – это файл – мы должны как-то сохранить информацию где и какой конкретно. Эту задачу решают
логи слепков, которые представляют собой простые текстовые файлы, где в конечной строке лежит путь к последнему
созданному слепку.

Т.е. мы просто пишем в этот файл названия созданных файлов, что-то в духе

```go
package snaplog

import (
	"bytes"
	"io"
	"os"
)

func writeLog(logName, snapshotFileName string) error {
	log, err := os.OpenFile(logName, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return errors.Wrap(err, "open snapshots logs to append a name")
	}
	defer func() {
		if log == nil {
			return
		}

		if err := log.Close(); err != nil {
			fmt.Printf("close log file descriptor after snapshot file name write failure: %s\n", err)
		}
	}()

	var buf bytes.Buffer
	buf.WriteByte('\n')
	buf.WriteString(snapshotFileName)
	buf.WriteByte('\n')
	if _, err := io.Copy(log, &buf); err != nil {
		return errors.Wrap(err, "write snapshot file name")
	}

	l := log
	log = nil
	if err := l.Close(); err != nil {
		return errors.Wrap(err, "close log file descriptor")
	}
	
	return nil
}
```

По логике кода понятно, что названием файла слепка будет считаться последняя непустая строка заканчивающаяся
`\n`.

Как видите, ничего сложного.

# Логи операций.

## Бинарное представление данных соответствующее записи.

Оно должно содержать индекс состояния соответствующий записи и саму запись. Кодирование выглядит следующим образом:

| 16 байт индекса | Длина данных записи (uleb128) | Бинарные данные записи |
|-----------------|-------------------------------|------------------------|

## Требования.

От логов операций нам в обязательном порядке требуется возможность поиска записи сделанной при определённом индексе
состояния. Это нужно для подхватывания далеко отставших клиентов, которые тем не менее всё ещё находятся на дистанции
лога.

При этом, если посмотреть, события сохранённые в логе всегда расположены в порядке возрастания индекса состояния.
Т.е. возникает соблазн использовать бинарный поиск. К сожалению, мы не можем сказать с какой позиции начинается
запись следующей операции если находимся на какой-то позиции в логе (кроме начальной) – это всё просто бинарные
данные. 

Навскидку, имеется несколько вариантов обхода этого ограничения:


### Разделение записей на несколько блоков по M байт.

Двоичные данные длины N бьются на K **блоков** по M байт каждая – последний может быть короче M. Содержимое последнего
байта блока указывает, является ли он последним содержащим данные записи, или содержит ещё дополнительные данные.
Недостатками подобного подхода являются:

- Повышенный расход дискового пространства: K - 1 байт + размер неиспользованной части последнего блока. 
- Необходимость вычитки дополнительных данных посередине, чтобы найти окончание записи – т.е. появляется много
  нелинейного чтения недетерминированного характера.

### Записи заканчиваются определённой кодовой последовательностью.

Здесь недостатками являются:

- Необходимость экранирования данных, чтобы скрыть кодовые последовательности в самих данных.
- Так же как и в предыдущем случае, придётся читать много данных посередине и количество чтений неопределённое.

### Записи размещаются в достаточно длинных кадрах длины N.

Подобранных так, чтобы в такой размер влезали несколько записей максимально допустимого размера. Если в кадре не 
хватает места для очередной записи, незанятый конец кадра заполняется нолями. Размер остатка кадра меньший минимально
допустимого размера записи (содержит 16 байт индекса + длина + содержимое записи = 18 байт) или 8 нулевых байтов
соответствующих нулевому сроку индекса говорит о том, что предыдущая запись была последней в кадре.

Недостатком такого подхода является необходимость линейного поиска записей в рамках кадра. Поиск же нужного кадра
– двоичный, с детерминированным количество чтений (строго одно) на каждом шаге поиска.

### Вывод.

Я склоняюсь к последнему варианту.