-- История медкарты и исследования. Измените номер карты на нужный.
SELECT h.performed_on,h.service_name,h.diagnosis_code,h.conclusion,r.name AS research,r.result
FROM card_service_history h
LEFT JOIN research r ON r.performed_service_id=h.id
WHERE h.card_id=1 ORDER BY h.performed_on,h.id,r.id;
-- Счета пациентов с рассчитанной суммой.
SELECT i.number,p.last_name,p.first_name,t.total,i.paid,i.status
FROM invoice i JOIN patient p ON p.id=i.patient_id
JOIN invoice_total t ON t.id=i.id ORDER BY i.issued_on,i.id;
-- Услуги, которые еще не оказывались.
SELECT s.code,s.name FROM service s
LEFT JOIN performed_service p ON p.service_id=s.id WHERE p.id IS NULL;
-- Число приемов каждого врача, включая врачей без приемов.
SELECT d.last_name,d.first_name,count(a.id) AS appointments
FROM doctor d LEFT JOIN schedule_slot s ON s.doctor_id=d.id
LEFT JOIN appointment a ON a.slot_id=s.id AND a.status<>'отменен'
GROUP BY d.id ORDER BY d.last_name;
