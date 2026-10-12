PRAGMA foreign_keys = ON;

DROP TABLE IF EXISTS account;
DROP TABLE IF EXISTS customer;
DROP TABLE IF EXISTS branch;

CREATE TABLE branch (
    branch_code   CHAR(3)      PRIMARY KEY,
    branch_name   VARCHAR(50)  NOT NULL UNIQUE,
    town          VARCHAR(40)  NOT NULL,
    county        VARCHAR(40)  NOT NULL
);

CREATE TABLE customer (
    customer_id     INTEGER      PRIMARY KEY,
    cif_number      VARCHAR(9)   NOT NULL UNIQUE,
    customer_type   VARCHAR(10)  NOT NULL CHECK (customer_type IN ('INDIVIDUAL', 'BUSINESS', 'GROUP')),
    full_name       VARCHAR(100) NOT NULL,
    id_number       VARCHAR(20)  NOT NULL UNIQUE,
    phone_number    VARCHAR(13)  NOT NULL,
    email           VARCHAR(100),
    customer_since  DATE         NOT NULL
);

CREATE TABLE account (
    account_id             INTEGER        PRIMARY KEY,
    account_number         VARCHAR(13)    NOT NULL UNIQUE CHECK (length(account_number) = 13),
    customer_id            INTEGER        NOT NULL REFERENCES customer (customer_id),
    branch_code            CHAR(3)        NOT NULL REFERENCES branch (branch_code),
    account_type           VARCHAR(10)    NOT NULL CHECK (account_type IN ('SAVINGS', 'CURRENT', 'SALARY', 'STUDENT', 'PREMIUM', 'BUSINESS', 'GROUP')),
    currency               CHAR(3)        NOT NULL DEFAULT 'KES' CHECK (currency IN ('KES', 'USD')),
    balance                DECIMAL(18,2)  NOT NULL DEFAULT 0,
    overdraft_limit        DECIMAL(18,2)  NOT NULL DEFAULT 0 CHECK (overdraft_limit >= 0),
    status                 VARCHAR(10)    NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'DORMANT', 'CLOSED')),
    opened_date            DATE           NOT NULL,
    last_transaction_date  DATE,
    closed_date            DATE,
    CHECK (balance >= -overdraft_limit),
    CHECK (overdraft_limit = 0 OR account_type IN ('CURRENT', 'PREMIUM', 'BUSINESS')),
    CHECK (status <> 'CLOSED' OR (balance = 0 AND overdraft_limit = 0 AND closed_date IS NOT NULL)),
    CHECK (status = 'CLOSED' OR closed_date IS NULL)
);

CREATE INDEX idx_account_customer ON account (customer_id);


-- DB RULES
-- A balance can't go below minus the overdraft limit.
-- Only current, premium and business accounts can have an overdraft.
-- A closed account must have a zero balance and a closed date.