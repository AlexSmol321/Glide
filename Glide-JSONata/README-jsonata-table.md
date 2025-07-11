# JSONata для красивой HTML-таблицы в Glide

Этот шаблон позволяет формировать красивую HTML-таблицу в Glide Apps с помощью JSONata, если стандартные средства Glide не позволяют склеить массив строк в одну HTML-строку.

## Особенности
- Работает только если количество строк фиксировано (например, 4).
- Для каждой строки таблицы прописана отдельная проверка и форматирование.
- Если строк меньше — лишние строки будут пустыми.
- Если строк больше — добавьте аналогичные блоки для каждой строки.
- Форматирует числа: если целое — без дробной части, иначе — до двух знаков после запятой.
- Для определённых строк (например, "Процент скидки:") применяется жирное выделение.

## Использование
1. Скопируйте выражение из файла `jsonata-table-template.txt`.
2. Вставьте его в Glide Apps в поле Custom → JSONata.
3. В качестве входных данных используйте объект с массивом `tableArray`, где каждая строка — объект с полями `column1` и (опционально) `column2`.
4. Результат будет одной HTML-строкой, которую можно отобразить в Rich Text компоненте Glide.

## Пример входных данных
```json
{
  "tableArray": [
    { "column1": "Мин. кол-во пластин для участия в программе DpQ:", "column2": 50 },
    { "column1": "Процент скидки:", "column2": 90 },
    { "column1": "Прайс-лист EUB, Евро, без НДС:", "column2": 100.4 },
    { "column1": "Цена за корпус с учетом скидки по программе DpQ, Евро, без НДС:", "column2": 10.04 },
    { "column1": "Доступно на складе в РФ:" }
  ]
}
```

## Пример результата
```html
<div style="font-family:sans-serif;font-size:14px;"><table style="width:100%;border-collapse:collapse;"><tr style="border-bottom:1px solid #d3d3d3;"><td style="padding:12px 8px;vertical-align:top;">Мин. кол-во пластин для участия в программе DpQ:</td><td style="padding:12px 8px;text-align:right;white-space:nowrap;">50</td></tr><tr style="border-bottom:1px solid #d3d3d3;"><td style="padding:12px 8px;vertical-align:top;"><strong>Процент скидки:</strong></td><td style="padding:12px 8px;text-align:right;white-space:nowrap;"><strong>90</strong></td></tr><tr style="border-bottom:1px solid #d3d3d3;"><td style="padding:12px 8px;vertical-align:top;">Прайс-лист EUB, Евро, без НДС:</td><td style="padding:12px 8px;text-align:right;white-space:nowrap;">100.4</td></tr><tr style=""><td style="padding:12px 8px;vertical-align:top;"><strong>Цена за корпус с учетом скидки по программе DpQ, Евро, без НДС:</strong></td><td style="padding:12px 8px;text-align:right;white-space:nowrap;"><strong>10.04</strong></td></tr></table></div>
``` 