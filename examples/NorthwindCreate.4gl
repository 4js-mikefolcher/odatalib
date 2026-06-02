################################################################################
# NorthwindCreate.4gl
#
# Builds a tiny in-memory Northwind-style schema and seeds it with sample data,
# so the example OData service and the smoke test have something to serve.
# Uses the SQLite driver (dbmsqt); no external database required.
################################################################################

#+ Create and populate the customers and orders tables in the current
#+ (already connected) database.
PUBLIC FUNCTION createDatabase()
    CREATE TABLE customers (
        customer_id CHAR(5),
        company_name VARCHAR(60),
        country VARCHAR(30)
    )
    CREATE TABLE orders (
        order_id INTEGER,
        customer_id CHAR(5),
        freight DECIMAL(10,2)
    )

    INSERT INTO customers VALUES ('ALFKI', 'Alfreds Futterkiste', 'Germany')
    INSERT INTO customers VALUES ('ANATR', 'Ana Trujillo Emparedados', 'Mexico')
    INSERT INTO customers VALUES ('BLAUS', 'Blauer See Delikatessen', 'Germany')
    INSERT INTO customers VALUES ('BSBEV', 'B''s Beverages', 'UK')
    INSERT INTO customers VALUES ('DRACD', 'Drachenblut Delikatessen', 'Germany')
    INSERT INTO customers VALUES ('FRANK', 'Frankenversand', 'Germany')

    INSERT INTO orders VALUES (10248, 'ALFKI', 32.38)
    INSERT INTO orders VALUES (10249, 'BLAUS', 11.61)
    INSERT INTO orders VALUES (10250, 'FRANK', 65.83)
    INSERT INTO orders VALUES (10251, 'ALFKI', 41.34)
END FUNCTION
