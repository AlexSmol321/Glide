/**
 * copyDataFromSourceToDestination.gs
 *
 * V22, 2025-01-XX
 * Изменения:
 * ──────────────────────────────────────────────────────────────
 * 1. **Полностью переработана логика отслеживания изменений в листе «Goods»**.
 *    • Добавлено отслеживание столбца «Состояние» наряду с количеством и датой.
 *    • Введены новые правила уведомлений на основе комбинации изменений:
 *      - Изменение состояния с «Ожидается по неподтвержденному заказу» на «Обеспечен к дате» → уведомление о дате поступления
 *      - Изменение состояния с «Ожидается по неподтвержденному заказу» на «Обеспечен к дате» + изменение количества → критическое уведомление
 *      - При состоянии «Обеспечен к дате» изменилась дата поступления → уведомление о дате поступления
 *      - При состоянии «Обеспечен к дате» изменилась дата поступления + изменение количества → критическое уведомление
 *      - Изменение состояния с любого на «Отгружено» → уведомление «Отгружено»
 *      - Изменение состояния с любого на «Отгружено» + изменение количества → критическое уведомление
 *    • При любых других изменениях уведомления НЕ отправляются.
 *
 * 2. Версия скрипта поднята до V22; остальной функционал (V21)
 *    остался без изменений.
 *
 * ──────────────────────────────────────────────────────────────
 *
 * V21, 2025-06-12
 * Изменения:
 * ──────────────────────────────────────────────────────────────
 * 1. Введена универсальная функция **ensureAccessColumns()**.
 *    • Гарантирует наличие и заполнение всех столбцов доступа:
 *      AccessAdmin | AccessStaff | AccessReader | Access/superAdmin
 *      а также, при флаге isWarehouse = true:
 *      Access/customer | Access/dealer.
 *    • Заполняет ПУСТЫЕ ячейки даже в уже существующих строках
 *      (чтобы устранить ситуации, когда строки из ExternalWarehouses
 *      приходили без значения «customer» / «dealer»).
 *    • Работает пакетно (один `setValues` на каждый столбец).
 *
 * 2. После копирования каждого листа вызывается ensureAccessColumns():
 *    • для «Warehouse» — с параметром *true*,
 *    • для остальных («Orders», «Goods», «Customers») — с *false*.
 *
 * 3. Версия скрипта поднята до V21; остальной функционал (V20)
 *    остался без изменений.
 *
 * ──────────────────────────────────────────────────────────────
 *
 * V20, 2025-06-06
 * Объединённое копирование + Access-столбцы + обрезка 50 000 симв.
 * (см. историю изменений в предыдущих версиях).
 */

function copyDataFromSourceToDestination() {

  /*════════════ 1. Константы ════════════*/
  const SOURCE_SPREADSHEET_ID      = '1BmCf52anGN1U6O4J6eCGMVeBsSeW1FuQufTZ5tr5hhw';
  const DESTINATION_SPREADSHEET_ID = '1jelGOYvjJpZXqHWjrcg-k0oBqH4CUlAkkIF6PBprdhg';
  const SYNC_SHEETS                = ['Orders', 'Goods', 'Customers', 'Warehouse'];

  const srcSS = SpreadsheetApp.openById(SOURCE_SPREADSHEET_ID);
  const dstSS = SpreadsheetApp.openById(DESTINATION_SPREADSHEET_ID);

  /*════════════ 2. toMoscowIso ════════════*/
  function toMoscowIso(val) {
    if (val instanceof Date) {
      return Utilities.formatDate(val, 'GMT+3', "yyyy-MM-dd'T'HH:mm:ss'+03:00'");
    }
    if (typeof val === 'string') {
      const s = val.trim();
      if (!s) return '';
      const re = /^(\d{2})\.(\d{2})\.(\d{4})(?:\s+(\d{1,2}):(\d{2}):(\d{2}))?$/;
      const m  = s.match(re);
      if (m) {
        const dt = new Date(+m[3], +m[2]-1, +m[1], m[4]||0, m[5]||0, m[6]||0);
        return Utilities.formatDate(dt, 'GMT+3', "yyyy-MM-dd'T'HH:mm:ss'+03:00'");
      }
      const d = new Date(s);
      if (!isNaN(d)) {
        return Utilities.formatDate(d, 'GMT+3', "yyyy-MM-dd'T'HH:mm:ss'+03:00'");
      }
      return s;
    }
    return '';
  }

  /*════════════ 3. ensureAccessColumns ════════════*/
  /**
   * Гарантирует наличие и ЗАПОЛНЕНИЕ столбцов доступа.
   *
   * @param {GoogleAppsScript.Spreadsheet.Sheet} sheet ─ лист-приёмник
   * @param {Boolean} isWarehouse ─ true ⇒ добавляем customer/dealer
   */
  function ensureAccessColumns(sheet, isWarehouse) {
    const baseHeaders = [
      'AccessAdmin', 'AccessStaff',
      'AccessReader', 'Access/superAdmin'
    ];
    const baseValues  = [
      'admin', 'staff',
      'reader', 'superAdmin'
    ];
    const whHeaders   = ['Access/customer', 'Access/dealer'];
    const whValues    = ['customer', 'dealer'];

    const reqHeaders = isWarehouse
      ? baseHeaders.concat(whHeaders)
      : baseHeaders;
    const reqValues  = isWarehouse
      ? baseValues .concat(whValues)
      : baseValues;

    /* ---- текущий заголовок ---- */
    const hdrRange = sheet.getRange(1, 1, 1, sheet.getLastColumn());
    const currHdr  = hdrRange.getValues()[0];

    /* ---- добавляем недостающие столбцы ---- */
    const missing = reqHeaders.filter(h => currHdr.indexOf(h) === -1);
    if (missing.length) {
      sheet.insertColumnsAfter(sheet.getLastColumn(), missing.length);
      hdrRange.offset(0, 0, 1, currHdr.length + missing.length)
              .setValues([currHdr.concat(missing)]);
    }

    /* ---- индексы целевых колонок ---- */
    const finalHdr = sheet.getRange(1, 1, 1, sheet.getLastColumn()).getValues()[0];
    const colIdx   = reqHeaders.map(h => finalHdr.indexOf(h) + 1); // 1-based

    const dataRows = sheet.getLastRow() - 1;
    if (dataRows <= 0) return;

    /* ---- заполняем ПУСТЫЕ ячейки ---- */
    reqHeaders.forEach((h, i) => {
      const col = colIdx[i];
      if (col < 1) return;
      const rng = sheet.getRange(2, col, dataRows, 1);
      const vals = rng.getValues();
      let needFill = false;
      for (let r=0; r<dataRows; r++) {
        if (vals[r][0] === '' || vals[r][0] === null) {
          vals[r][0] = reqValues[i];
          needFill = true;
        }
      }
      if (needFill) rng.setValues(vals);
    });
  }

  /*════════════ 4. Изменения «Goods» (сбор уведомлений) ════════════*/
  const changesByUID = {};   // { uid: { order: [ ... ] } }

  (function processGoods() {
    const src = srcSS.getSheetByName('Goods');
    const dst = dstSS.getSheetByName('Goods');
    if (!src || !dst) { Logger.log('Лист «Goods» не найден.'); return; }

    const oldVals = dst.getDataRange().getValues();
    const oldHdr  = oldVals[0] || [];
    const oIdx    = {
      uid  : oldHdr.indexOf('УИД'),
      ord  : oldHdr.indexOf('НомерЗаказа'),
      nom  : oldHdr.indexOf('Номенклатура'),
      qty  : oldHdr.indexOf('Количество'),
      date : oldHdr.indexOf('ДатаПоступления'),
      status: oldHdr.indexOf('Состояние')
    };
    const oldMap = {};
    if (oldVals.length > 1 && oIdx.uid >= 0) {
      for (let i=1;i<oldVals.length;i++) {
        const r = oldVals[i];
        const key = r[oIdx.uid]+'||'+r[oIdx.ord]+'||'+r[oIdx.nom];
        (oldMap[key]=oldMap[key]||[]).push({
          q : r[oIdx.qty],
          d : toMoscowIso(r[oIdx.date]),
          s : r[oIdx.status] || ''
        });
      }
    }

    const newVals = src.getDataRange().getValues();
    const nHdr    = newVals[0] || [];
    const nIdx    = {
      uid  : nHdr.indexOf('УИД'),
      ord  : nHdr.indexOf('НомерЗаказа'),
      nom  : nHdr.indexOf('Номенклатура'),
      qty  : nHdr.indexOf('Количество'),
      date : nHdr.indexOf('ДатаПоступления'),
      status: nHdr.indexOf('Состояние')
    };

    if (nIdx.uid >= 0) {
      for (let r=1;r<newVals.length;r++) {
        const row   = newVals[r];
        const uid   = row[nIdx.uid];
        const ord   = row[nIdx.ord];
        const nom   = row[nIdx.nom];
        const qty   = row[nIdx.qty];
        const iso   = toMoscowIso(row[nIdx.date]);
        const newStatus = row[nIdx.status] || '';
        const key   = uid+'||'+ord+'||'+nom;

        const arrOld = oldMap[key] || [];
        if (arrOld.length) {
          let hit=-1;
          for (let k=0;k<arrOld.length;k++){
            if(arrOld[k].q === qty) { hit=k; break; }
          }
          if (hit>-1) {
            const oldIso = arrOld[hit].d;
            const oldStatus = arrOld[hit].s;
            arrOld.splice(hit,1);
            if(!arrOld.length) delete oldMap[key];
            
            // Проверяем новые правила уведомлений
            const qtyChanged = false; // количество не изменилось
            const dateChanged = oldIso !== iso;
            const statusChanged = oldStatus !== newStatus;
            
            checkAndRecordChange(uid, ord, nom, iso, newStatus, oldStatus, qtyChanged, dateChanged, statusChanged);
          } else {
            // Количество изменилось
            const oldStatus = arrOld[0]?.s || '';
            checkAndRecordChange(uid, ord, nom, iso, newStatus, oldStatus, true, false, oldStatus !== newStatus);
          }
        } else {
          // Новая запись
          checkAndRecordChange(uid, ord, nom, iso, newStatus, '', true, false, false);
        }
      }
      /* удалённые строки */
      for (const k in oldMap) {
        const p    = k.split('||');
        const uid  = p[0], ord=p[1], nom=p[2];
        oldMap[k].forEach(e => recordChange(uid, ord, nom, e.d, 'Удалено', e.s, true, false, false));
      }
    }

    /* ---- запись листа «Goods» ---- */
    dst.clear();
    dst.getRange(1,1,newVals.length,nHdr.length).setValues(newVals);
    ensureAccessColumns(dst,false); // базовые 4 колонки
  })();

  /* helper: проверка и запись изменений по новым правилам */
  function checkAndRecordChange(uid, ord, nom, iso, newStatus, oldStatus, qtyChanged, dateChanged, statusChanged) {
    let shouldNotify = false;
    let notificationType = '';
    let note = '';

    // Правило 1: Изменение состояния с "Ожидается по неподтвержденному заказу" на "Обеспечен к дате"
    if (statusChanged && oldStatus === 'Ожидается по неподтвержденному заказу' && newStatus === 'Обеспечен к дате') {
      shouldNotify = true;
      if (qtyChanged) {
        notificationType = 'critical';
        note = 'Есть изменения, пожалуйста, уточните в приложении!';
      } else {
        notificationType = 'date';
        note = '';
      }
    }
    // Правило 2: При состоянии "Обеспечен к дате" изменилась дата поступления
    else if (newStatus === 'Обеспечен к дате' && dateChanged && !statusChanged) {
      shouldNotify = true;
      if (qtyChanged) {
        notificationType = 'critical';
        note = 'Есть изменения, пожалуйста, уточните в приложении!';
      } else {
        notificationType = 'date';
        note = '';
      }
    }
    // Правило 3: Изменение состояния с любого на "Отгружено"
    else if (statusChanged && newStatus === 'Отгружено') {
      shouldNotify = true;
      if (qtyChanged) {
        notificationType = 'critical';
        note = 'Есть изменения, пожалуйста, уточните в приложении!';
      } else {
        notificationType = 'shipped';
        note = '';
      }
    }

    if (shouldNotify) {
      recordChange(uid, ord, nom, iso, newStatus, notificationType, note);
    }
  }

  /* helper: запись изменений */
  function recordChange(uid, ord, nom, iso, status, type, note) {
    (changesByUID[uid]=changesByUID[uid]||{})[ord] =
      (changesByUID[uid][ord]||[]).concat([{
        nomen: nom, 
        isoDate: iso,
        status: status,
        type: type,
        note: note
      }]);
  }

  /*════════════ 5. Копирование остальных листов ════════════*/
  SYNC_SHEETS.forEach(name => {
    if (name === 'Goods') return; // уже обработали

    const srcSh = srcSS.getSheetByName(name);
    const dstSh = dstSS.getSheetByName(name);
    if (!srcSh || !dstSh) { Logger.log(`Sheet ${name} not found.`); return; }

    const r   = srcSh.getDataRange();
    const v   = r.getValues();
    dstSh.clear();
    dstSh.getRange(1,1,v.length,v[0].length).setValues(v);

    /* Access-колонки */
    ensureAccessColumns(dstSh, name === 'Warehouse');
  });

  /*════════════ 6. Logins → LoginsLog ════════════*/
  (function syncLogins(){
    const logins = dstSS.getSheetByName('App: Logins');
    const log    = dstSS.getSheetByName('LoginsLog');
    if(!logins||!log){ Logger.log('Logins sheets missing'); return; }

    const data = logins.getRange('A:B').getValues();
    log.clear();
    log.getRange(1,1,data.length,2).setValues(data);
    ensureAccessColumns(log,false);
  })();

  /*════════════ 7. Карты клиентов ════════════*/
  const innMap={}, clientMap={};
  (function buildMaps(){
    const sh = dstSS.getSheetByName('Customers');
    if(!sh) return;
    const v = sh.getDataRange().getValues();
    if(v.length<2) return;
    const h = v[0];
    const ix={ uid:h.indexOf('УИД'), inn:h.indexOf('ИНН'), cl:h.indexOf('Клиент') };
    for(let i=1;i<v.length;i++){
      const r=v[i]; innMap[r[ix.uid]]=r[ix.inn]; clientMap[r[ix.uid]]=r[ix.cl];
    }
  })();

  /*════════════ 8. Notifications ════════════*/
  (function writeNotifications(){
    const sh = dstSS.getSheetByName('Notifications');
    if(!sh){ Logger.log('Notifications sheet missing'); return; }

    sh.clear();
    sh.getRange(1,1,1,5).setValues([[
      'УИД','Message','formatedMessage','managerFormatedMessage','processed'
    ]]);

    const out=[];
    Object.keys(changesByUID).forEach(uid=>{
      const orders=changesByUID[uid];
      const msgLines=[], tbl=[];
      Object.keys(orders).forEach(ord=>{
        orders[ord].forEach(it=>{
          if(it.type === 'critical'){
            msgLines.push(`Номер заказа ${ord}: ${it.nomen} (Комментарий: ${it.note})`);
            tbl.push(`<tr><td style="white-space:nowrap;">${ord}</td><td>${it.nomen}</td><td style="white-space:nowrap;"></td><td>${it.note}</td></tr>`);
          } else if(it.type === 'date'){
            const d=Utilities.formatDate(new Date(it.isoDate),'GMT+3','dd.MM.yy');
            msgLines.push(`Номер заказа ${ord}: ${it.nomen}`);
            tbl.push(`<tr><td style="white-space:nowrap;">${ord}</td><td>${it.nomen}</td><td style="white-space:nowrap;">${d}</td><td></td></tr>`);
          } else if(it.type === 'shipped'){
            msgLines.push(`Номер заказа ${ord}: ${it.nomen} - Отгружено`);
            tbl.push(`<tr><td style="white-space:nowrap;">${ord}</td><td>${it.nomen}</td><td style="white-space:nowrap;"></td><td>Отгружено</td></tr>`);
          }
        });
      });

      let message = msgLines.join('; ');
      if(message.length>50000) message = message.slice(0,50000);

      const client = clientMap[uid]||'';
      const inn    = innMap[uid]   ||'';
      const clientLine = `<p>Клиент: ${client}</p>`;
      const table     = `<table border="1" cellpadding="3" cellspacing="0" style="width:auto;"><tr><th>Номер заказа</th><th>Номенклатура</th><th>Дата поступления</th><th>Примечание</th></tr>${tbl.join('')}</table>`;

      const fm  = (clientLine+table).slice(0,50000);
      const mfm = (`<p>ИНН: ${inn}</p>`+clientLine+table).slice(0,50000);

      out.push([uid,message,fm,mfm,false]);
    });

    if(out.length) sh.getRange(2,1,out.length,5).setValues(out);
  })();
}
