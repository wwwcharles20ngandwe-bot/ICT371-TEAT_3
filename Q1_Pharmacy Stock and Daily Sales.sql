
-- TABLE 1: MEDICINES
CREATE TABLE medicines (
    medicine_id SERIAL PRIMARY KEY,
    medicine_name VARCHAR(100) NOT NULL,
    unit_price NUMERIC(10,2) NOT NULL
        CHECK (unit_price > 0),
    stock_qty INTEGER NOT NULL
        CHECK (stock_qty >= 0)
);

-- TABLE 2: SALES
CREATE TABLE sales (
    sale_id SERIAL PRIMARY KEY,
    medicine_id INTEGER NOT NULL,
    quantity INTEGER NOT NULL
        CHECK (quantity > 0),
    unit_price NUMERIC(10,2) NOT NULL
        CHECK (unit_price > 0),
    sold_on DATE NOT NULL,

    CONSTRAINT fk_sales_medicine
        FOREIGN KEY (medicine_id)
        REFERENCES medicines(medicine_id)
);

-- TABLE 3: STOCK AUDIT
CREATE TABLE stock_audit (
    audit_id SERIAL PRIMARY KEY,
    medicine_id INTEGER NOT NULL,
    old_qty INTEGER NOT NULL,
    new_qty INTEGER NOT NULL,
    changed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT fk_audit_medicine
        FOREIGN KEY (medicine_id)
        REFERENCES medicines(medicine_id)
);

-- TABLE 4: DAILY SALES
CREATE TABLE daily_sales (
    sales_date DATE PRIMARY KEY,
    total_qty INTEGER NOT NULL DEFAULT 0,
    total_amount NUMERIC(12,2) NOT NULL DEFAULT 0
);



INSERT INTO medicines
(medicine_name, unit_price, stock_qty)
VALUES
('Paracetamol', 5.00, 100),
('Amoxicillin', 12.00, 80),
('Ibuprofen', 8.00, 60);




CREATE OR REPLACE FUNCTION fn_sale_value(
    p_medicine_id INTEGER,
    p_quantity INTEGER
)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10,2);
BEGIN

    -- Check quantity
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION
        'Quantity must be greater than zero';
    END IF;

    -- Get current medicine price
    SELECT unit_price
    INTO v_price
    FROM medicines
    WHERE medicine_id = p_medicine_id;

    -- Check medicine existence
    IF NOT FOUND THEN
        RAISE EXCEPTION
        'Medicine ID % does not exist',
        p_medicine_id;
    END IF;

    -- Return total value
    RETURN v_price * p_quantity;

END;
$$;



CREATE OR REPLACE PROCEDURE pr_record_sale(
    p_medicine_id INTEGER,
    p_quantity INTEGER,
    p_sold_on DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10,2);
BEGIN

    -- Validate quantity
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION
        'Quantity must be greater than zero';
    END IF;

    -- Validate sale date
    IF p_sold_on IS NULL THEN
        RAISE EXCEPTION
        'Sale date cannot be NULL';
    END IF;

    -- Check whether medicine exists
    IF NOT EXISTS (
        SELECT 1
        FROM medicines
        WHERE medicine_id = p_medicine_id
    ) THEN
        RAISE EXCEPTION
        'Medicine ID % does not exist',
        p_medicine_id;
    END IF;

    -- Deduct stock only when sufficient stock exists.
    -- RETURNING captures the current price.
    UPDATE medicines
    SET stock_qty = stock_qty - p_quantity
    WHERE medicine_id = p_medicine_id
      AND stock_qty >= p_quantity
    RETURNING unit_price INTO v_price;

    -- Reject insufficient stock
    IF NOT FOUND THEN
        RAISE EXCEPTION
        'Insufficient stock for medicine ID %',
        p_medicine_id;
    END IF;

    -- Record the sale using the captured price
    INSERT INTO sales (
        medicine_id,
        quantity,
        unit_price,
        sold_on
    )
    VALUES (
        p_medicine_id,
        p_quantity,
        v_price,
        p_sold_on
    );

END;
$$;



CREATE OR REPLACE FUNCTION fn_stock_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN

    IF OLD.stock_qty IS DISTINCT FROM NEW.stock_qty THEN

        INSERT INTO stock_audit (
            medicine_id,
            old_qty,
            new_qty,
            changed_at
        )
        VALUES (
            NEW.medicine_id,
            OLD.stock_qty,
            NEW.stock_qty,
            CURRENT_TIMESTAMP
        );

    END IF;

    RETURN NEW;

END;
$$;



CREATE OR REPLACE VIEW v_low_stock AS
SELECT
    medicine_id,
    medicine_name,
    unit_price,
    stock_qty
FROM medicines
WHERE stock_qty < 10;



CREATE INDEX idx_sales_medicine_date
ON sales (medicine_id, sold_on);

The composite index (medicine_id, sold_on) improves searches involving a specific medicine and a date range. It reduces the amount of data PostgreSQL may need to examine, especially when the sales table becomes large.

SELECT
    sale_id,
    medicine_id,
    quantity,
    unit_price,
    sold_on
FROM sales
WHERE medicine_id = 1
AND sold_on BETWEEN
    DATE '2026-11-01'
    AND DATE '2026-11-25';


EXPLAIN
SELECT
    sale_id,
    medicine_id,
    quantity,
    unit_price,
    sold_on
FROM sales
WHERE medicine_id = 1
AND sold_on BETWEEN
    DATE '2026-11-01'
    AND DATE '2026-11-25';


CREATE OR REPLACE PROCEDURE pr_refresh_sales(
    p_day DATE
)
LANGUAGE plpgsql
AS $$
BEGIN

    -- Reject a NULL date
    IF p_day IS NULL THEN
        RAISE EXCEPTION
        'Sales date cannot be NULL';
    END IF;

    -- Calculate and replace daily totals
    INSERT INTO daily_sales (
        sales_date,
        total_qty,
        total_amount
    )
    SELECT
        p_day,
        COALESCE(SUM(quantity), 0),
        COALESCE(SUM(quantity * unit_price), 0)
    FROM sales
    WHERE sold_on = p_day

    ON CONFLICT (sales_date)
    DO UPDATE SET
        total_qty = EXCLUDED.total_qty,
        total_amount = EXCLUDED.total_amount;

END;
$$;