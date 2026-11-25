-- =====================================================================
-- ICT371 Advanced Database | Question 4: Clinic Appointment Scheduling
-- Target DBMS: PostgreSQL 14+ (PL/pgSQL). Scheduling uses the pg_cron extension.
-- Run with:  psql -d your_database -f Q4_Clinic_Appointment_Scheduling.sql
-- Slots: 09:00, 10:00, 11:00, 12:00. Statuses: BOOKED, ATTENDED, CANCELLED.
-- =====================================================================

-- ---------------------------------------------------------------------
-- (a) Database and seed data
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS clinic_summary, appointments, doctors, patients CASCADE;

CREATE TABLE patients (
    patient_id  SERIAL       PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL
);

CREATE TABLE doctors (
    doctor_id  SERIAL       PRIMARY KEY,
    full_name  VARCHAR(100) NOT NULL
);

CREATE TABLE appointments (
    appointment_id   SERIAL      PRIMARY KEY,
    patient_id       INTEGER     NOT NULL REFERENCES patients (patient_id),
    doctor_id        INTEGER     NOT NULL REFERENCES doctors  (doctor_id),
    appointment_day  DATE        NOT NULL,
    slot_time        TIME        NOT NULL,
    status           VARCHAR(10) NOT NULL DEFAULT 'BOOKED',
    CONSTRAINT ck_slot_time CHECK (slot_time IN (TIME '09:00', TIME '10:00', TIME '11:00', TIME '12:00')),
    CONSTRAINT ck_status    CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED'))
);

CREATE TABLE clinic_summary (
    summary_date    DATE    PRIMARY KEY,
    booked_count    INTEGER NOT NULL DEFAULT 0,
    attended_count  INTEGER NOT NULL DEFAULT 0,
    cancelled_count INTEGER NOT NULL DEFAULT 0
);

INSERT INTO patients (full_name) VALUES
    ('Natasha Lungu'), ('Kelvin Mwale'), ('Esther Sakala');

INSERT INTO doctors (full_name) VALUES
    ('Dr. Banda'), ('Dr. Phiri'), ('Dr. Chileshe');

-- ---------------------------------------------------------------------
-- (b) Function fn_daily_load
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INTEGER, p_day DATE)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_count INTEGER;
BEGIN
    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;

    -- COUNT(*) returns 0 when the day has no bookings
    SELECT COUNT(*) INTO v_count
    FROM appointments
    WHERE doctor_id = p_doctor_id
      AND appointment_day = p_day
      AND status <> 'CANCELLED';

    RETURN v_count;
END;
$$;

-- ---------------------------------------------------------------------
-- (c) Procedure pr_book_appointment
--     The clash check itself is done by the trigger in (d).
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_book_appointment(p_patient_id INTEGER, p_doctor_id INTEGER, p_day DATE, p_slot TIME)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM 1 FROM patients WHERE patient_id = p_patient_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown patient_id: %', p_patient_id;
    END IF;

    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;

    IF p_day IS NULL OR p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Appointment date % is NULL or in the past', p_day;
    END IF;

    IF p_slot IS NULL OR p_slot NOT IN (TIME '09:00', TIME '10:00', TIME '11:00', TIME '12:00') THEN
        RAISE EXCEPTION 'Unsupported slot: % (use 09:00, 10:00, 11:00 or 12:00)', p_slot;
    END IF;

    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END;
$$;

-- ---------------------------------------------------------------------
-- (d) Trigger: reject clashes (BEFORE INSERT OR UPDATE, row level)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_appointment_clash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    -- A cancelled appointment does not occupy a slot, so it can never clash
    IF NEW.status <> 'CANCELLED' THEN
        IF EXISTS (
            SELECT 1
            FROM appointments a
            WHERE a.doctor_id       = NEW.doctor_id
              AND a.appointment_day = NEW.appointment_day
              AND a.slot_time       = NEW.slot_time
              AND a.status         <> 'CANCELLED'
              AND a.appointment_id IS DISTINCT FROM NEW.appointment_id  -- exclude the row being changed
        ) THEN
            RAISE EXCEPTION 'Clash: doctor % already has a non-cancelled appointment on % at %',
                            NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_appointment_clash ON appointments;
CREATE TRIGGER trg_appointment_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_appointment_clash();

-- Extra safety net against two sessions racing each other (the trigger alone
-- cannot see uncommitted rows of another transaction):
CREATE UNIQUE INDEX uq_active_slot
    ON appointments (doctor_id, appointment_day, slot_time)
    WHERE status <> 'CANCELLED';

-- ---------------------------------------------------------------------
-- (e) View: v_today_appointments (only names, slot; no other patient data)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT p.full_name AS patient_name,
       d.full_name AS doctor_name,
       a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors  d ON d.doctor_id  = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE
  AND a.status = 'BOOKED';

-- ---------------------------------------------------------------------
-- (f) Non-unique index for searches by appointment_day and doctor_id
--     Both are equality filters in the typical query "doctor X on day Y".
-- ---------------------------------------------------------------------
CREATE INDEX idx_appointments_day_doctor ON appointments (appointment_day, doctor_id);

-- ---------------------------------------------------------------------
-- (g) Scheduled job: pr_refresh_clinic_summary (replaces that date's row)
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Day must not be NULL';
    END IF;

    INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
    SELECT p_day,
           COUNT(*) FILTER (WHERE status = 'BOOKED'),
           COUNT(*) FILTER (WHERE status = 'ATTENDED'),
           COUNT(*) FILTER (WHERE status = 'CANCELLED')
    FROM appointments
    WHERE appointment_day = p_day
    ON CONFLICT (summary_date)
    DO UPDATE SET booked_count    = EXCLUDED.booked_count,
                  attended_count  = EXCLUDED.attended_count,
                  cancelled_count = EXCLUDED.cancelled_count;
END;
$$;

CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Every day at 01:00, for the previous day
SELECT cron.schedule(
    'clinic_refresh_summary',
    '0 1 * * *',
    $$CALL pr_refresh_clinic_summary(CURRENT_DATE - 1)$$
);

-- =====================================================================
-- DEMONSTRATION / TESTING
-- =====================================================================

-- (a) Six appointments (no slot clash)
CALL pr_book_appointment(1, 1, CURRENT_DATE,     TIME '09:00');
CALL pr_book_appointment(2, 1, CURRENT_DATE,     TIME '10:00');
CALL pr_book_appointment(3, 2, CURRENT_DATE,     TIME '09:00');   -- same slot, different doctor: OK
CALL pr_book_appointment(1, 2, CURRENT_DATE + 1, TIME '11:00');
CALL pr_book_appointment(2, 3, CURRENT_DATE + 1, TIME '12:00');
CALL pr_book_appointment(3, 3, CURRENT_DATE + 2, TIME '09:00');

-- Change some statuses (the UPDATE path of the trigger; the row itself is excluded from the clash search)
UPDATE appointments SET status = 'ATTENDED'  WHERE appointment_id = 1;
UPDATE appointments SET status = 'CANCELLED' WHERE appointment_id = 5;

SELECT * FROM appointments ORDER BY appointment_id;

-- (b) Function tests
SELECT fn_daily_load(1, CURRENT_DATE)     AS dr_banda_today,   -- 2 (ATTENDED + BOOKED)
       fn_daily_load(3, CURRENT_DATE + 1) AS dr_chileshe_tmrw, -- 0 (the only one is cancelled)
       fn_daily_load(2, CURRENT_DATE + 30) AS no_bookings;     -- 0
-- SELECT fn_daily_load(99, CURRENT_DATE);   -- ERROR: Unknown doctor_id

-- (c)/(d) Rejections (uncomment one at a time)
-- CALL pr_book_appointment(2, 1, CURRENT_DATE, TIME '09:00');       -- ERROR: Clash (trigger)
-- CALL pr_book_appointment(1, 1, CURRENT_DATE - 1, TIME '09:00');   -- ERROR: past date
-- CALL pr_book_appointment(1, 1, CURRENT_DATE + 3, TIME '13:00');   -- ERROR: unsupported slot
-- CALL pr_book_appointment(99, 1, CURRENT_DATE + 3, TIME '09:00');  -- ERROR: unknown patient
-- UPDATE appointments SET slot_time = TIME '09:00' WHERE appointment_id = 2;  -- ERROR: Clash (direct SQL)

-- A cancelled slot can be booked again
CALL pr_book_appointment(1, 3, CURRENT_DATE + 1, TIME '12:00');

-- (e) View
SELECT * FROM v_today_appointments ORDER BY slot_time, doctor_name;

-- (f) EXPLAIN (seqscan disabled only because the demo table is tiny)
SET enable_seqscan = off;
EXPLAIN
SELECT *
FROM appointments
WHERE appointment_day = CURRENT_DATE
  AND doctor_id = 1;
RESET enable_seqscan;

-- (g) Rerun-safe summary
CALL pr_refresh_clinic_summary(CURRENT_DATE);
CALL pr_refresh_clinic_summary(CURRENT_DATE);
SELECT * FROM clinic_summary ORDER BY summary_date;

SELECT jobid, jobname, schedule, command, active FROM cron.job;
