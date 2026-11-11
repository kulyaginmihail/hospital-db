"""Локальное учебное рабочее место администратора больницы."""
import os, secrets, hmac
from functools import wraps
from datetime import date, datetime
import psycopg
from psycopg import sql
from psycopg.rows import dict_row
from flask import Flask, request, session, redirect, url_for, render_template, abort, flash
from werkzeug.security import generate_password_hash, check_password_hash
from metadata import TABLES, LABELS, OPTIONS, GROUPS

app=Flask(__name__)
app.secret_key=os.environ.get('SECRET_KEY') or secrets.token_hex(32)
app.config.update(SESSION_COOKIE_HTTPONLY=True,SESSION_COOKIE_SAMESITE='Lax',MAX_CONTENT_LENGTH=1024*1024)
DSN=os.environ.get('DATABASE_URL','postgresql://localhost:5432/hospital')
def connect():
    conn=psycopg.connect(DSN,row_factory=dict_row)
    conn.execute('SET TRANSACTION ISOLATION LEVEL SERIALIZABLE')
    return conn

def authorized(view):
    @wraps(view)
    def wrapper(*args,**kwargs):
        if not session.get('user_id'): return redirect(url_for('login'))
        with connect() as c:
            u=c.execute('SELECT active,role FROM account WHERE id=%s',(session['user_id'],)).fetchone()
        if not u or not u['active'] or u['role']!='администратор':
            session.clear(); return redirect(url_for('login'))
        return view(*args,**kwargs)
    return wrapper

@app.before_request
def csrf():
    if 'csrf' not in session: session['csrf']=secrets.token_hex(32)
    if request.method=='POST' and not hmac.compare_digest(session['csrf'],request.form.get('csrf','')): abort(400)

@app.context_processor
def common(): return dict(tables=TABLES,labels=LABELS,groups=GROUPS,csrf=session.get('csrf'),username=session.get('login'))

@app.route('/login',methods=['GET','POST'])
def login():
    error=None
    if request.method=='POST':
        with connect() as c:
            u=c.execute('SELECT * FROM account WHERE login=%s',(request.form.get('login'),)).fetchone()
        if u and u['active'] and u['role']=='администратор' and check_password_hash(u['password_hash'],request.form.get('password','')):
            session.clear(); session.update(user_id=u['id'],login=u['login'],csrf=secrets.token_hex(32))
            return redirect(url_for('home'))
        error='Неверные данные или нет доступа администратора.'
    return render_template('login.html',title='Вход',error=error)

@app.post('/logout')
def logout():
    session.clear(); return redirect(url_for('login'))

def columns(c,table):
    rows=c.execute("""SELECT column_name AS name, data_type AS type, domain_name,
    is_nullable='YES' AS nullable, column_default FROM information_schema.columns
    WHERE table_schema='public' AND table_name=%s ORDER BY ordinal_position""",(table,)).fetchall()
    fks=c.execute("""SELECT kcu.column_name,ccu.table_name AS target
    FROM information_schema.table_constraints tc
    JOIN information_schema.key_column_usage kcu ON tc.constraint_name=kcu.constraint_name AND tc.constraint_schema=kcu.constraint_schema
    JOIN information_schema.constraint_column_usage ccu ON ccu.constraint_name=tc.constraint_name AND ccu.constraint_schema=tc.constraint_schema
    WHERE tc.constraint_type='FOREIGN KEY' AND tc.table_schema='public' AND tc.table_name=%s""",(table,)).fetchall()
    refs={r['column_name']:r['target'] for r in fks}
    for r in rows:
        r['label']=LABELS.get(r['name'],r['name']); r['target']=refs.get(r['name'])
        r['options']=OPTIONS.get((table,r['name']))
    return rows

def row_label(c,table,row):
    if not row: return ''
    rid=row['id']
    if table in ('patient','doctor'): text=' '.join(str(row.get(k) or '') for k in ('last_name','first_name','middle_name')).strip()
    elif table=='medical_card':
        p=c.execute('SELECT * FROM patient WHERE id=%s',(row['patient_id'],)).fetchone()
        text=f"Карта {row['number']} · {p['last_name']} {p['first_name']}"
    elif table=='schedule_slot':
        p=c.execute('SELECT * FROM doctor WHERE id=%s',(row['doctor_id'],)).fetchone()
        text=f"{row['starts_at']:%d.%m.%Y %H:%M} · {p['last_name']} {p['first_name']}"
    elif table=='appointment':
        p=c.execute('SELECT p.* FROM patient p JOIN medical_card c ON c.patient_id=p.id WHERE c.id=%s',(row['card_id'],)).fetchone()
        text=f"{p['last_name']} {p['first_name']} · {row['status']}"
    elif table=='performed_service':
        p=c.execute('SELECT s.name,p.last_name FROM service s,appointment a JOIN medical_card c ON c.id=a.card_id JOIN patient p ON p.id=c.patient_id WHERE s.id=%s AND a.id=%s',(row['service_id'],row['appointment_id'])).fetchone()
        text=f"{p['name']} · {p['last_name']} · {row['performed_on']}"
    elif table=='invoice': text=f"Счет {row['number']} · {row['status']}"
    elif table=='position': text=f"{row['name']} · ставка {row['rate']}"
    else: text=row.get('name') or row.get('login') or str(rid)
    return f"{text} (№ {rid})"

def options(c,table):
    return [(r['id'],row_label(c,table,r)) for r in c.execute(sql.SQL('SELECT * FROM {} ORDER BY id').format(sql.Identifier(table))).fetchall()]

def valid_table(table):
    if table not in TABLES: abort(404)

@app.get('/')
@authorized
def home():
    with connect() as c:
        counts={t:c.execute(sql.SQL('SELECT count(*) AS n FROM {}').format(sql.Identifier(t))).fetchone()['n'] for t in TABLES}
        upcoming=c.execute('''SELECT a.id,p.last_name,p.first_name,s.starts_at,d.last_name AS doctor,a.status
        FROM appointment a JOIN medical_card m ON m.id=a.card_id JOIN patient p ON p.id=m.patient_id
        JOIN schedule_slot s ON s.id=a.slot_id JOIN doctor d ON d.id=s.doctor_id
        WHERE a.status IN ('запланирован','идет') ORDER BY s.starts_at LIMIT 6''').fetchall()
    return render_template('home.html',title='Обзор',counts=counts,upcoming=upcoming)

@app.get('/table/<table>')
@authorized
def listing(table):
    valid_table(table)
    page=max(1,request.args.get('page',1,type=int)); q=request.args.get('q','').strip()
    with connect() as c:
        cols=[x for x in columns(c,table) if x['name']!='password_hash']
        allrows=c.execute(sql.SQL('SELECT * FROM {} ORDER BY id').format(sql.Identifier(table))).fetchall()
        lookups={x['name']:dict(options(c,x['target'])) for x in cols if x['target']}
        data=[]
        for r in allrows:
            shown={x['name']:lookups[x['name']].get(r[x['name']],'') if x['target'] else r[x['name']] for x in cols}
            if not q or q.casefold() in ' '.join(str(v) for v in shown.values()).casefold(): data.append(shown)
        if table=='invoice':
            totals={r['id']:r['total'] for r in c.execute('SELECT * FROM invoice_total').fetchall()}
            cols.extend([dict(name='total',label='Сумма, руб.'),dict(name='payment_state',label='Оплата')])
            for r in data:
                r['total']=totals[r['id']]
                r['payment_state']='Отменен' if r['status']=='отменен' else 'Не требуется' if r['total']==0 else 'Оплачен' if r['paid'] else 'Не оплачен'
        total=len(data); data=data[(page-1)*25:page*25]
    return render_template('list.html',title=TABLES[table],table=table,cols=cols,rows=data,page=page,total=total,q=q)

def db_error(e):
    if e.sqlstate=='23503': return 'Запись связана с другой таблицей. Проверьте ссылки; используемую запись удалить нельзя.'
    if e.sqlstate=='23505': return 'Такая запись уже существует. Номер, код или время приема должны быть уникальны.'
    if e.sqlstate=='23P01': return 'Интервалы работы врача пересекаются. Выберите другое время.'
    if e.sqlstate in ('23514','23502','22001','22P02','22007','22008','22003'): return 'Недопустимое значение. Проверьте обязательные поля, даты, числа и формат данных.'
    if e.sqlstate=='P0001': return e.diag.message_primary
    if e.sqlstate=='40001': return 'Данные одновременно изменены другим пользователем. Повторите сохранение.'
    app.logger.error('Database operation failed: SQLSTATE %s',e.sqlstate)
    return 'Не удалось сохранить данные. Проверьте соединение с базой.'

@app.route('/table/<table>/new',methods=['GET','POST'])
@app.route('/table/<table>/<int:rid>/edit',methods=['GET','POST'])
@authorized
def edit(table,rid=None):
    valid_table(table); error=None; status=200
    with connect() as c:
        cols=[x for x in columns(c,table) if x['name']!='id']
        row=c.execute(sql.SQL('SELECT * FROM {} WHERE id=%s').format(sql.Identifier(table)),(rid,)).fetchone() if rid else {}
        if rid and row is None: abort(404)
        choices={x['name']:options(c,x['target']) for x in cols if x['target']}
    if request.method=='POST':
        row=request.form.to_dict(); values={}
        try:
            for x in cols:
                key=x['name']; v=request.form.get(key,'').strip()
                if key=='password_hash':
                    if not v and rid: continue
                    if len(v)<8: raise ValueError('Пароль должен содержать не менее 8 символов.')
                    v=generate_password_hash(v)
                elif x['type']=='boolean': v=v=='true'
                elif not v: v=None
                values[key]=v
            with connect() as c:
                if rid:
                    query=sql.SQL('UPDATE {} SET {} WHERE id=%s').format(sql.Identifier(table),sql.SQL(',').join(sql.SQL('{}=%s').format(sql.Identifier(k)) for k in values))
                    c.execute(query,[*values.values(),rid])
                else:
                    query=sql.SQL('INSERT INTO {} ({}) VALUES ({})').format(sql.Identifier(table),sql.SQL(',').join(map(sql.Identifier,values)),sql.SQL(',').join(sql.Placeholder() for _ in values))
                    c.execute(query,list(values.values()))
            flash('Изменения сохранены.'); return redirect(url_for('listing',table=table))
        except psycopg.Error as e: error=db_error(e); status=400
        except ValueError as e: error=str(e); status=400
    if table=='account': row=dict(row); row['password_hash']=''
    return render_template('form.html',title=('Изменение записи' if rid else 'Новая запись'),table=table,cols=cols,row=row,choices=choices,rid=rid,error=error),status

@app.route('/table/<table>/<int:rid>/delete',methods=['GET','POST'])
@authorized
def delete(table,rid):
    valid_table(table); error=None
    with connect() as c:
        row=c.execute(sql.SQL('SELECT * FROM {} WHERE id=%s').format(sql.Identifier(table)),(rid,)).fetchone()
        if not row: abort(404)
        label=row_label(c,table,row)
    if request.method=='POST':
        if table=='account' and rid==session['user_id']: error='Нельзя удалить свою активную учетную запись.'
        else:
            try:
                with connect() as c: c.execute(sql.SQL('DELETE FROM {} WHERE id=%s').format(sql.Identifier(table)),(rid,))
                flash('Запись удалена.'); return redirect(url_for('listing',table=table))
            except psycopg.Error as e: error=db_error(e)
    return render_template('delete.html',title='Удаление записи',table=table,label=label,error=error),400 if error else 200

@app.get('/card/<int:rid>')
@authorized
def history(rid):
    with connect() as c:
        card=c.execute('SELECT * FROM medical_card WHERE id=%s',(rid,)).fetchone()
        if not card: abort(404)
        label=row_label(c,'medical_card',card)
        rows=c.execute('SELECT * FROM card_service_history WHERE card_id=%s ORDER BY performed_on,id',(rid,)).fetchall()
        research=c.execute('SELECT r.* FROM research r JOIN card_service_history h ON h.id=r.performed_service_id WHERE h.card_id=%s ORDER BY r.id',(rid,)).fetchall()
    return render_template('history.html',title=label,rows=rows,research=research)

@app.template_filter('display')
def display(v):
    if v is None or v=='': return 'Не указано'
    if isinstance(v,bool): return 'Да' if v else 'Нет'
    if isinstance(v,datetime): return v.strftime('%d.%m.%Y %H:%M')
    if isinstance(v,date): return v.strftime('%d.%m.%Y')
    return v

if __name__=='__main__': app.run(host='127.0.0.1',port=int(os.environ.get('PORT','8000')),debug=False)
