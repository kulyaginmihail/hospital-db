import sys,re,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from app import app,connect,TABLES
import psycopg

class ProjectTest(unittest.TestCase):
    def setUp(self):
        self.client=app.test_client()
        self.client.get('/login')
        with self.client.session_transaction() as s: self.token=s['csrf']
        r=self.client.post('/login',data={'csrf':self.token,'login':'admin','password':'HospitalDemo2026!'})
        self.assertEqual(r.status_code,302)
        with self.client.session_transaction() as s: self.token=s['csrf']
    def post(self,url,data={}): return self.client.post(url,data={**data,'csrf':self.token})
    def test_all_tables_crud(self):
        ids={}; forms={}
        fixtures=[
        ('organization',dict(name='Тестовая организация',address='Тестовый адрес',okpo='87654321')),
        ('benefit_category',dict(name='Тестовая льгота',discount='3')),
        ('patient',dict(last_name='Тестов',first_name='Тест',birth_date='2000-01-01',sex='М')),
        ('medical_card',dict(number='TEST-CARD',opened_on='2026-11-01')),
        ('position',dict(name='Тестовая должность',rate='0.25')),
        ('doctor',dict(last_name='Тестов',first_name='Врач',specialty='Тест',active='true')),
        ('service',dict(code='TEST-SERVICE',name='Тестовая услуга',price='100',duration_minutes='30',active='true')),
        ('diagnosis',dict(code='TEST-DIAGNOSIS',name='Тестовый диагноз')),
        ('schedule_slot',dict(starts_at='2026-12-01T10:00',ends_at='2026-12-01T10:30',available='true')),
        ('appointment',dict(complaints='Тест',status='идет')),
        ('performed_service',dict(performed_on='2026-12-01',quantity='1',funding='платно',conclusion='Тест')),
        ('research',dict(name='Тестовое исследование',status='назначено')),
        ('invoice',dict(number='TEST-INVOICE',issued_on='2026-12-01',status='черновик',paid='false')),
        ('invoice_line',dict(unit_price='100',discount='3')),
        ('account',dict(login='test_project_account',password_hash='OnlyTest2026!',role='пациент',active='true'))]
        refs={'patient':{'benefit_category_id':'benefit_category'},'medical_card':{'patient_id':'patient','organization_id':'organization'},'doctor':{'position_id':'position'},'schedule_slot':{'doctor_id':'doctor'},'appointment':{'card_id':'medical_card','slot_id':'schedule_slot','planned_service_id':'service'},'performed_service':{'appointment_id':'appointment','service_id':'service','diagnosis_id':'diagnosis'},'research':{'performed_service_id':'performed_service'},'invoice':{'patient_id':'patient'},'invoice_line':{'invoice_id':'invoice','performed_service_id':'performed_service'},'account':{'patient_id':'patient'}}
        try:
            for t,f in fixtures:
                f.update({k:str(ids[v]) for k,v in refs.get(t,{}).items()}); forms[t]=f
                self.assertEqual(self.client.get('/table/'+t).status_code,200,t)
                self.assertEqual(self.client.get('/table/'+t+'/new').status_code,200,t)
                r=self.post('/table/'+t+'/new',f)
                self.assertEqual(r.status_code,302,(t,r.data.decode()[:700]))
                with connect() as c: ids[t]=c.execute('SELECT max(id) AS id FROM '+t).fetchone()['id']
                self.assertEqual(self.client.get(f'/table/{t}/{ids[t]}/edit').status_code,200,t)
                self.assertEqual(self.post(f'/table/{t}/{ids[t]}/edit',f).status_code,302,t)
            self.assertEqual(self.client.get('/card/'+str(ids['medical_card'])).status_code,200)
        finally:
            for t in reversed(ids):
                self.assertEqual(self.post(f'/table/{t}/{ids[t]}/delete').status_code,302,t)
    def test_sql_constraints(self):
        cases=[
        ('владелец карты',"UPDATE medical_card SET patient_id=3 WHERE id=1"),
        ('скидка',"INSERT INTO benefit_category(name,discount) VALUES ('bad',101)"),
        ('цена',"UPDATE service SET price=-1 WHERE id=1"),
        ('будущая дата рождения',"UPDATE patient SET birth_date=CURRENT_DATE+1 WHERE id=1"),
        ('внешний ключ',"UPDATE doctor SET position_id=999999 WHERE id=1"),
        ('уникальный код',"INSERT INTO diagnosis(code,name) VALUES ('Z00.0','Повтор')"),
        ('пересечение расписания',"INSERT INTO schedule_slot(doctor_id,starts_at,ends_at) VALUES (1,'2026-11-12 10:10','2026-11-12 10:40')"),
        ('двойная запись',"INSERT INTO appointment(card_id,slot_id,planned_service_id) VALUES (3,2,1)"),
        ('переход статуса',"UPDATE appointment SET status='завершен' WHERE id=2"),
        ('исследование без результата',"UPDATE research SET result=NULL WHERE id=1"),
        ('оплата без даты',"UPDATE invoice SET paid=true WHERE id=1"),
        ('изменение выставленного счета',"UPDATE invoice_line SET discount=50 WHERE id=1"),
        ('изменение оказанной услуги в счете',"UPDATE performed_service SET quantity=2 WHERE id=1"),
        ('удаление пациента со связями',"DELETE FROM patient WHERE id=1"),
        ('роль учетной записи',"UPDATE account SET role='пациент' WHERE login='admin'"),
        ('использованный слот',"UPDATE schedule_slot SET starts_at=starts_at+interval '1 minute' WHERE id=2"),
        ('пустой счет',"INSERT INTO invoice(patient_id,number,status) VALUES (1,'bad','выставлен')")]
        for label,query in cases:
            with self.subTest(label=label):
                with connect() as c:
                    with self.assertRaises(psycopg.Error) as caught:
                        with c.transaction(): c.execute(query)
                    if label=='владелец карты': self.assertEqual(caught.exception.sqlstate,'P0001')
    def test_web_rejection_and_rollback(self):
        with connect() as c: before=c.execute('SELECT count(*) n FROM benefit_category').fetchone()['n']
        r=self.post('/table/benefit_category/new',dict(name='Недопустимая скидка',discount='150'))
        self.assertEqual(r.status_code,400)
        self.assertIn('Изменения не сохранены',r.data.decode())
        with connect() as c: self.assertEqual(c.execute('SELECT count(*) n FROM benefit_category').fetchone()['n'],before)
        self.assertEqual(self.client.post('/table/service/1/delete').status_code,400)
    def test_history_and_invoice(self):
        with connect() as c:
            self.assertEqual(c.execute('SELECT card_id FROM card_service_history WHERE id=1').fetchone()['card_id'],1)
            self.assertEqual(c.execute('SELECT total FROM invoice_total WHERE id=1').fetchone()['total'],1500)
        self.assertIn('Профилактический осмотр завершен',self.client.get('/card/1').data.decode())
    def test_auth(self):
        c=app.test_client()
        self.assertEqual(c.get('/table/patient').status_code,302)
        self.assertNotIn('scrypt:',self.client.get('/table/account').data.decode())

if __name__=='__main__': unittest.main(verbosity=2)
