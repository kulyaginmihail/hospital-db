-- Запускать только в новой пустой учебной базе hospital.
BEGIN;
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE DOMAIN nonempty_text AS text CHECK (length(btrim(VALUE)) > 0);
CREATE DOMAIN money_amount AS numeric(12,2) CHECK (VALUE >= 0);
CREATE DOMAIN percent_value AS numeric(5,2) CHECK (VALUE BETWEEN 0 AND 100);
CREATE DOMAIN positive_int AS integer CHECK (VALUE > 0);
CREATE DOMAIN phone_text AS varchar(20) CHECK (VALUE ~ '^\+?[0-9 ()-]{7,20}$');
CREATE TABLE organization (
 id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 name nonempty_text NOT NULL, address nonempty_text NOT NULL, okpo varchar(10),
 CHECK (okpo IS NULL OR okpo ~ '^([0-9]{8}|[0-9]{10})$')
);
CREATE TABLE benefit_category (
 id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 name nonempty_text NOT NULL UNIQUE, discount percent_value NOT NULL DEFAULT 0
);
CREATE TABLE patient (
 id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 last_name nonempty_text NOT NULL, first_name nonempty_text NOT NULL, middle_name text,
 birth_date date NOT NULL CHECK (birth_date <= CURRENT_DATE),
 sex varchar(1) NOT NULL CHECK (sex IN ('М','Ж')),
 address text, phone phone_text, snils varchar(11) UNIQUE CHECK (snils ~ '^[0-9]{11}$'),
 policy_number varchar(16) UNIQUE CHECK (policy_number ~ '^[0-9]{16}$'),
 insurer text, identity_document text,
 benefit_category_id integer REFERENCES benefit_category(id) ON DELETE RESTRICT
);
CREATE TABLE medical_card (
 id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 patient_id integer NOT NULL UNIQUE REFERENCES patient(id) ON DELETE RESTRICT,
 organization_id integer NOT NULL REFERENCES organization(id) ON DELETE RESTRICT,
 number nonempty_text NOT NULL UNIQUE, opened_on date NOT NULL DEFAULT CURRENT_DATE
);
CREATE TABLE position (
 id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 name nonempty_text NOT NULL, rate numeric(3,2) NOT NULL CHECK (rate > 0 AND rate <= 2),
 UNIQUE(name,rate)
);
CREATE TABLE doctor (
 id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 last_name nonempty_text NOT NULL, first_name nonempty_text NOT NULL, middle_name text,
 specialty nonempty_text NOT NULL, position_id integer NOT NULL REFERENCES position(id) ON DELETE RESTRICT,
 phone phone_text, active boolean NOT NULL DEFAULT true
);
CREATE TABLE service (
 id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 code nonempty_text NOT NULL UNIQUE, name nonempty_text NOT NULL,
 price money_amount NOT NULL, duration_minutes positive_int NOT NULL,
 active boolean NOT NULL DEFAULT true
);
CREATE TABLE diagnosis (
 id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 code nonempty_text NOT NULL UNIQUE, name nonempty_text NOT NULL
);
CREATE TABLE schedule_slot (
 id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 doctor_id integer NOT NULL REFERENCES doctor(id) ON DELETE RESTRICT,
 starts_at timestamp NOT NULL, ends_at timestamp NOT NULL,
 available boolean NOT NULL DEFAULT true,
 CHECK (ends_at > starts_at),
 EXCLUDE USING gist (doctor_id WITH =, tsrange(starts_at,ends_at,'[)') WITH &&)
);
CREATE TABLE appointment (
 id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 card_id integer NOT NULL REFERENCES medical_card(id) ON DELETE RESTRICT,
 slot_id integer NOT NULL REFERENCES schedule_slot(id) ON DELETE RESTRICT,
 planned_service_id integer NOT NULL REFERENCES service(id) ON DELETE RESTRICT,
 complaints text,
 status varchar(20) NOT NULL DEFAULT 'запланирован'
 CHECK (status IN ('запланирован','идет','завершен','отменен','неявка'))
);
CREATE UNIQUE INDEX one_active_booking ON appointment(slot_id) WHERE status <> 'отменен';
CREATE TABLE performed_service (
 id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 appointment_id integer NOT NULL REFERENCES appointment(id) ON DELETE RESTRICT,
 service_id integer NOT NULL REFERENCES service(id) ON DELETE RESTRICT,
 performed_on date NOT NULL DEFAULT CURRENT_DATE, quantity positive_int NOT NULL DEFAULT 1,
 funding varchar(10) NOT NULL CHECK (funding IN ('ОМС','платно')),
 diagnosis_id integer REFERENCES diagnosis(id) ON DELETE RESTRICT,
 additional_diagnoses text, examination text, conclusion text, prescription text
);
CREATE TABLE research (
 id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 performed_service_id integer NOT NULL REFERENCES performed_service(id) ON DELETE RESTRICT,
 name nonempty_text NOT NULL, research_date date, result text,
 status varchar(15) NOT NULL DEFAULT 'назначено' CHECK (status IN ('назначено','выполнено')),
 CHECK (status <> 'выполнено' OR (research_date IS NOT NULL AND length(btrim(result)) > 0 AND result IS NOT NULL))
);
CREATE TABLE invoice (
 id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 patient_id integer NOT NULL REFERENCES patient(id) ON DELETE RESTRICT,
 number nonempty_text NOT NULL UNIQUE, issued_on date NOT NULL DEFAULT CURRENT_DATE,
 status varchar(15) NOT NULL DEFAULT 'черновик' CHECK (status IN ('черновик','выставлен','отменен')),
 paid boolean NOT NULL DEFAULT false, paid_on date,
 CHECK ((paid AND paid_on IS NOT NULL AND status = 'выставлен' AND paid_on >= issued_on) OR (NOT paid AND paid_on IS NULL))
);
CREATE TABLE invoice_line (
 id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 invoice_id integer NOT NULL REFERENCES invoice(id) ON DELETE RESTRICT,
 performed_service_id integer NOT NULL UNIQUE REFERENCES performed_service(id) ON DELETE RESTRICT,
 unit_price money_amount NOT NULL, discount percent_value NOT NULL DEFAULT 0
);
CREATE TABLE account (
 id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 login nonempty_text NOT NULL UNIQUE, password_hash nonempty_text NOT NULL,
 role varchar(20) NOT NULL CHECK (role IN ('администратор','регистратор','врач','пациент','кассир')),
 patient_id integer UNIQUE REFERENCES patient(id) ON DELETE RESTRICT,
 doctor_id integer UNIQUE REFERENCES doctor(id) ON DELETE RESTRICT,
 active boolean NOT NULL DEFAULT true,
 CHECK ((role='пациент' AND patient_id IS NOT NULL AND doctor_id IS NULL)
 OR (role='врач' AND doctor_id IS NOT NULL AND patient_id IS NULL)
 OR (role IN ('администратор','регистратор','кассир') AND patient_id IS NULL AND doctor_id IS NULL))
);
-- Медкарта получается по единственной связи с приемом, без дублирования card_id.
CREATE VIEW card_service_history AS
 SELECT p.*, a.card_id, s.name AS service_name, d.code AS diagnosis_code
 FROM performed_service p JOIN appointment a ON a.id=p.appointment_id
 JOIN service s ON s.id=p.service_id LEFT JOIN diagnosis d ON d.id=p.diagnosis_id;
CREATE VIEW invoice_total AS
 SELECT i.id, COALESCE(sum(round(p.quantity*l.unit_price*(1-l.discount/100),2)),0) AS total
 FROM invoice i LEFT JOIN invoice_line l ON l.invoice_id=i.id
 LEFT JOIN performed_service p ON p.id=l.performed_service_id GROUP BY i.id;
CREATE FUNCTION check_appointment() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE sl schedule_slot; other_status text;
BEGIN
 SELECT * INTO sl FROM schedule_slot WHERE id=NEW.slot_id;
 IF TG_OP='UPDATE' AND OLD.status <> NEW.status AND NOT
 ((OLD.status='запланирован' AND NEW.status IN ('идет','отменен','неявка')) OR (OLD.status='идет' AND NEW.status='завершен')) THEN
 RAISE EXCEPTION 'Недопустимый переход статуса приема'; END IF;
 IF TG_OP='UPDATE' AND (OLD.card_id<>NEW.card_id OR OLD.slot_id<>NEW.slot_id OR OLD.planned_service_id<>NEW.planned_service_id)
 AND (OLD.status<>'запланирован' OR EXISTS(SELECT 1 FROM performed_service WHERE appointment_id=OLD.id)) THEN
 RAISE EXCEPTION 'Нельзя переносить прием с результатами'; END IF;
 IF NEW.status IN ('запланирован','идет') THEN
 IF NOT sl.available OR NOT (SELECT active FROM doctor WHERE id=sl.doctor_id) THEN RAISE EXCEPTION 'Время или врач недоступны'; END IF;
 IF NOT (SELECT active FROM service WHERE id=NEW.planned_service_id) THEN RAISE EXCEPTION 'Услуга недоступна'; END IF;
 IF (SELECT duration_minutes FROM service WHERE id=NEW.planned_service_id) > EXTRACT(EPOCH FROM sl.ends_at-sl.starts_at)/60 THEN RAISE EXCEPTION 'Интервал короче длительности услуги'; END IF;
 IF EXISTS(SELECT 1 FROM appointment a JOIN schedule_slot s ON s.id=a.slot_id
 WHERE a.card_id=NEW.card_id AND a.id<>NEW.id AND a.status IN ('запланирован','идет')
 AND tsrange(s.starts_at,s.ends_at,'[)') && tsrange(sl.starts_at,sl.ends_at,'[)')) THEN
 RAISE EXCEPTION 'У пациента уже есть прием в это время'; END IF;
 END IF;
 IF NEW.status='завершен' AND (NOT EXISTS(SELECT 1 FROM performed_service WHERE appointment_id=NEW.id)
 OR EXISTS(SELECT 1 FROM performed_service WHERE appointment_id=NEW.id AND (diagnosis_id IS NULL OR COALESCE(btrim(conclusion),'')=''))) THEN
 RAISE EXCEPTION 'Для завершения нужны услуга, диагноз и заключение'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER appointment_rules BEFORE INSERT OR UPDATE ON appointment FOR EACH ROW EXECUTE FUNCTION check_appointment();
CREATE FUNCTION check_reference_update() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_TABLE_NAME='medical_card' THEN
 IF NEW.patient_id<>OLD.patient_id AND EXISTS(SELECT 1 FROM appointment WHERE card_id=OLD.id) THEN
 RAISE EXCEPTION 'Нельзя менять владельца карты с историей приемов'; END IF;
 RETURN NEW;
 END IF;
 IF (NEW.doctor_id,NEW.starts_at,NEW.ends_at) IS DISTINCT FROM (OLD.doctor_id,OLD.starts_at,OLD.ends_at)
 AND EXISTS(SELECT 1 FROM appointment WHERE slot_id=OLD.id) THEN RAISE EXCEPTION 'Использованный интервал нельзя менять'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER slot_rules BEFORE UPDATE ON schedule_slot FOR EACH ROW EXECUTE FUNCTION check_reference_update();
CREATE TRIGGER card_owner_rules BEFORE UPDATE ON medical_card FOR EACH ROW EXECUTE FUNCTION check_reference_update();
CREATE FUNCTION check_performed_service() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE a appointment;
BEGIN
 IF TG_OP <> 'INSERT' THEN
 IF EXISTS(SELECT 1 FROM invoice_line WHERE performed_service_id=OLD.id) THEN
 RAISE EXCEPTION 'Услуга включена в счет. Сначала удалите строку черновика'; END IF;
 IF (SELECT status FROM appointment WHERE id=OLD.appointment_id)='завершен' THEN RAISE EXCEPTION 'Результаты завершенного приема защищены'; END IF;
 END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF;
 SELECT * INTO a FROM appointment WHERE id=NEW.appointment_id;
 IF a.status<>'идет' THEN RAISE EXCEPTION 'Результаты добавляются во время приема'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER performed_rules BEFORE INSERT OR UPDATE OR DELETE ON performed_service FOR EACH ROW EXECUTE FUNCTION check_performed_service();
CREATE FUNCTION check_invoice_line() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE inv invoice; owner_id integer; source text;
BEGIN
 IF TG_OP<>'INSERT' AND (SELECT status FROM invoice WHERE id=OLD.invoice_id)<>'черновик' THEN
 RAISE EXCEPTION 'Строки выставленного или отмененного счета защищены'; END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF;
 SELECT * INTO inv FROM invoice WHERE id=NEW.invoice_id FOR UPDATE;
 IF inv.status<>'черновик' THEN RAISE EXCEPTION 'Строки можно менять только в черновике'; END IF;
 SELECT c.patient_id,p.funding INTO owner_id,source FROM performed_service p
 JOIN appointment a ON a.id=p.appointment_id JOIN medical_card c ON c.id=a.card_id WHERE p.id=NEW.performed_service_id;
 IF owner_id<>inv.patient_id OR source<>'платно' THEN RAISE EXCEPTION 'В счет входят только платные услуги этого пациента'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER invoice_line_rules BEFORE INSERT OR UPDATE OR DELETE ON invoice_line FOR EACH ROW EXECUTE FUNCTION check_invoice_line();
CREATE FUNCTION check_invoice() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP='DELETE' THEN
 IF OLD.status<>'черновик' THEN RAISE EXCEPTION 'Удалять можно только черновик'; END IF;
 RETURN OLD;
 END IF;
 IF TG_OP='INSERT' AND (NEW.status<>'черновик' OR NEW.paid) THEN RAISE EXCEPTION 'Новый счет должен быть черновиком'; END IF;
 IF TG_OP='UPDATE' THEN
 IF OLD.status='отменен' OR OLD.paid THEN RAISE EXCEPTION 'Отмененный или оплаченный счет защищен'; END IF;
 IF (NEW.patient_id<>OLD.patient_id) AND EXISTS(SELECT 1 FROM invoice_line WHERE invoice_id=OLD.id) THEN RAISE EXCEPTION 'Нельзя менять пациента счета со строками'; END IF;
 IF OLD.status='выставлен' AND ((NEW.patient_id,NEW.number,NEW.issued_on) IS DISTINCT FROM (OLD.patient_id,OLD.number,OLD.issued_on) OR NEW.status='черновик') THEN
 RAISE EXCEPTION 'Реквизиты выставленного счета защищены'; END IF;
 IF NEW.status='выставлен' AND NOT EXISTS(SELECT 1 FROM invoice_line WHERE invoice_id=NEW.id) THEN RAISE EXCEPTION 'Нельзя выставить пустой счет'; END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER invoice_rules BEFORE INSERT OR UPDATE OR DELETE ON invoice FOR EACH ROW EXECUTE FUNCTION check_invoice();
CREATE INDEX appointment_card_idx ON appointment(card_id);
CREATE INDEX performed_appointment_idx ON performed_service(appointment_id);
CREATE INDEX research_performed_idx ON research(performed_service_id);
CREATE INDEX invoice_patient_idx ON invoice(patient_id);
CREATE INDEX invoice_line_invoice_idx ON invoice_line(invoice_id);
COMMIT;
