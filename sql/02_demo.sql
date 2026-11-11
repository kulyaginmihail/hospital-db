-- Вымышленные учебные данные. Выполнить один раз после 01_schema.sql.
BEGIN;
INSERT INTO organization(name,address,okpo) VALUES ('Учебная городская больница','г. Тюмень, Учебная ул., д. 1','12345678');
INSERT INTO benefit_category(name,discount) VALUES ('Пенсионер',10),('Студент',5);
INSERT INTO patient(last_name,first_name,middle_name,birth_date,sex,address,phone,benefit_category_id) VALUES
('Соколова','Анна','Игоревна','1998-04-12','Ж','г. Тюмень, Примерная ул., д. 8','+79000000001',NULL),
('Орлов','Иван','Петрович','1958-06-20','М','г. Тюмень, Примерная ул., д. 12','+79000000002',1),
('Морозова','Елена','Андреевна','2005-02-15','Ж','г. Тюмень, Примерная ул., д. 15','+79000000003',2);
INSERT INTO medical_card(patient_id,organization_id,number,opened_on) VALUES (1,1,'МК-001','2026-11-01'),(2,1,'МК-002','2026-11-01'),(3,1,'МК-003','2026-11-01');
INSERT INTO position(name,rate) VALUES ('Врач-терапевт',1),('Врач-кардиолог',0.5);
INSERT INTO doctor(last_name,first_name,middle_name,specialty,position_id,phone) VALUES
('Лебедева','Ольга','Сергеевна','Терапия',1,'+79000000004'),('Павлов','Алексей','Викторович','Кардиология',2,'+79000000005');
INSERT INTO service(code,name,price,duration_minutes) VALUES ('S001','Прием терапевта',1500,30),('S002','Прием кардиолога',2200,30),('S003','Электрокардиография',800,20);
INSERT INTO diagnosis(code,name) VALUES ('Z00.0','Общий медицинский осмотр'),('J06.9','Острая инфекция верхних дыхательных путей неуточненная');
INSERT INTO schedule_slot(doctor_id,starts_at,ends_at) VALUES
(1,'2026-11-11 09:00','2026-11-11 09:30'),(1,'2026-11-12 10:00','2026-11-12 10:30'),
(2,'2026-11-12 11:00','2026-11-12 11:30'),(1,'2026-11-12 10:30','2026-11-12 11:00');
INSERT INTO appointment(card_id,slot_id,planned_service_id,complaints) VALUES
(1,1,1,'Плановый осмотр'),(2,2,1,'Слабость'),(3,3,2,'Плановая консультация');
UPDATE appointment SET status='идет' WHERE id=1;
INSERT INTO performed_service(appointment_id,service_id,performed_on,quantity,funding,diagnosis_id,examination,conclusion,prescription)
VALUES(1,1,'2026-11-11',1,'платно',1,'Учебная запись осмотра','Профилактический осмотр завершен','Учебная запись рекомендаций');
INSERT INTO research(performed_service_id,name,research_date,result,status) VALUES (1,'Учебное исследование','2026-11-11','Демонстрационный результат','выполнено');
UPDATE appointment SET status='завершен' WHERE id=1;
INSERT INTO invoice(patient_id,number,issued_on) VALUES (1,'СЧ-001','2026-11-11');
INSERT INTO invoice_line(invoice_id,performed_service_id,unit_price,discount) VALUES (1,1,1500,0);
UPDATE invoice SET status='выставлен' WHERE id=1;
COMMIT;
