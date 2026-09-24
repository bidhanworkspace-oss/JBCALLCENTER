-- ===========================================================================
--  *** SUPERSEDED - DO NOT USE ***
--  This legacy patch has been folded into:
--    - JB_CALLCENTER_SETUP.sql      (brand-new install, no triggers/sequences)
--    - JB_CALLCENTER_MIGRATION_NO_TRIGGER_SEQUENCE.sql  (upgrade of existing DB)
--  Use one of those two files instead of this one.
-- ===========================================================================
--  JB CALL CENTER - TICKET SYSTEM + PROFILE/MANAGER FIXES (ORACLE)
-- ---------------------------------------------------------------------------
--  Written against the ACTUAL schema of 172.18.18.166:1521/JBPAY
--    Tables : USERDETAIL, USER_REGISTRATION, SYSTEM_MENU, SYSTEM_ROLE,
--             ROLE_MENU_PERMISSION, USER_ACTION_AUDIT_LOG
--  Run as the JBCALLCENTER schema user (the same user Django connects with).
--
--  What this script does
--    A. Adds IMAGE_PATH to USERDETAIL (manager / user photos).
--    B. Replaces SP_CREATE_MANAGER_BY_SUPERADMIN so it stores the photo.
--    C. Creates profile + dashboard SPs (SP_GET_USER_DETAILS,
--       SP_GET_ACTIVE_USERS, SP_GET_LOCKED_USERS).
--    D. Creates the ticket tables + sequences + triggers.
--    E. Creates the ticket SPs (raise / list / detail / respond).
--    F. Registers the Tickets menu items and grants them to the roles.
--
--  DESIGN RULE: Django views contain NO SQL. Everything goes through the
--  SP_* procedures below.
-- ===========================================================================
/

-- ===========================================================================
--  SECTION A. USER PHOTO COLUMN
-- ===========================================================================
DECLARE
    v_cnt NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_cnt
    FROM ALL_TAB_COLUMNS
    WHERE OWNER = USER AND TABLE_NAME = 'USERDETAIL' AND COLUMN_NAME = 'IMAGE_PATH';
    IF v_cnt = 0 THEN
        EXECUTE IMMEDIATE 'ALTER TABLE USERDETAIL ADD (IMAGE_PATH VARCHAR2(500))';
    END IF;
END;
/

-- ===========================================================================
--  SECTION B. CREATE MANAGER PROCEDURE (NOW WITH PHOTO)
--  Django passes: (p_superadmin_user_id, p_fullname, p_mobile, p_email,
--                  p_nid, p_image_path, p_temp_password,
--                  o_bank_id, o_success, o_msg)
-- ===========================================================================
CREATE OR REPLACE PROCEDURE SP_CREATE_MANAGER_BY_SUPERADMIN (
    p_superadmin_user_id IN NUMBER,
    p_fullname IN VARCHAR2,
    p_mobile IN VARCHAR2,
    p_email IN VARCHAR2,
    p_nid IN VARCHAR2,
    p_image_path IN VARCHAR2,
    p_temp_password IN VARCHAR2,
    p_gen_bank_id OUT VARCHAR2,
    p_success OUT NUMBER,
    p_msg OUT VARCHAR2
) AS
    v_role_id NUMBER;
    v_superadmin_role VARCHAR2(50);
BEGIN
    -- Verify executing user is Superadmin
    SELECT UPPER(r.ROLE_NAME) INTO v_superadmin_role
    FROM USERDETAIL u
    JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
    WHERE u.USERDETAILID = p_superadmin_user_id;

    IF v_superadmin_role != 'SUPERADMIN' THEN
        p_success := 0;
        p_msg := 'Access Denied: Only Superadmin can create Manager accounts.';
        RETURN;
    END IF;

    -- Get Manager Role ID
    SELECT ROLE_ID INTO v_role_id FROM SYSTEM_ROLE WHERE UPPER(ROLE_NAME) = 'MANAGER';

    p_gen_bank_id := 'MGR' || SEQ_BANK_ID.NEXTVAL;

    INSERT INTO USERDETAIL (
        BANKID, FULLNAME, MOBILE_NO, EMAIL, NID, IMAGE_PATH, USERPASSWORD,
        ROLE_ID, IS_FIRST_LOGIN, USERSTATUS, APPROVED_BY_USER_ID, APPROVED_AT
    ) VALUES (
        p_gen_bank_id, p_fullname, p_mobile, p_email, p_nid, p_image_path, p_temp_password,
        v_role_id, 1, 'Enabled', p_superadmin_user_id, CURRENT_TIMESTAMP
    );

    p_success := 1;
    p_msg := 'Manager account created successfully.';
    COMMIT;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        p_success := 0;
        p_msg := 'Superadmin or Manager role definition missing.';
    WHEN OTHERS THEN
        p_success := 0;
        p_msg := SQLERRM;
END;
/

-- ===========================================================================
--  SECTION C. PROFILE + DASHBOARD PROCEDURES
-- ===========================================================================

-- C1. Profile used by Django right after login (topbar photo).
CREATE OR REPLACE PROCEDURE SP_GET_USER_DETAILS (
    p_user_id     IN  NUMBER,
    o_fullname    OUT VARCHAR2,
    o_email       OUT VARCHAR2,
    o_image_path  OUT VARCHAR2,
    o_role_name   OUT VARCHAR2,
    o_success     OUT NUMBER
) AS
BEGIN
    o_fullname   := NULL;
    o_email      := NULL;
    o_image_path := NULL;
    o_role_name  := NULL;
    o_success    := 0;

    SELECT u.FULLNAME, u.EMAIL, u.IMAGE_PATH, r.ROLE_NAME
      INTO o_fullname, o_email, o_image_path, o_role_name
      FROM USERDETAIL u
      JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
     WHERE u.USERDETAILID = p_user_id;

    o_success := 1;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        o_success := 0;
    WHEN OTHERS THEN
        o_success := 0;
END;
/

-- C2. All active (Enabled) users for the manager dashboard.
-- Column order MUST match Django:
-- bank_id, fullname, mobile, email, role_name, image_path, status, created_at
CREATE OR REPLACE PROCEDURE SP_GET_ACTIVE_USERS (
    p_out_cursor OUT SYS_REFCURSOR
) AS
BEGIN
    OPEN p_out_cursor FOR
        SELECT u.BANKID,
               u.FULLNAME,
               u.MOBILE_NO,
               u.EMAIL,
               r.ROLE_NAME,
               u.IMAGE_PATH,
               u.USERSTATUS,
               u.APPROVED_AT
        FROM   USERDETAIL u
        JOIN   SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
        WHERE  UPPER(u.USERSTATUS) = 'ENABLED'
          AND  UPPER(r.ROLE_NAME) <> 'SUPERADMIN'
        ORDER  BY u.APPROVED_AT DESC NULLS LAST, u.FULLNAME;
END;
/

-- C3. Locked / Disabled users for the manager dashboard.
-- Column order MUST match Django:
-- bank_id, fullname, email, status, failed_attempts
CREATE OR REPLACE PROCEDURE SP_GET_LOCKED_USERS (
    p_out_cursor OUT SYS_REFCURSOR
) AS
BEGIN
    OPEN p_out_cursor FOR
        SELECT u.BANKID,
               u.FULLNAME,
               u.EMAIL,
               u.USERSTATUS,
               u.FAILED_ATTEMPTS
        FROM   USERDETAIL u
        WHERE  UPPER(u.USERSTATUS) <> 'ENABLED'
        ORDER  BY u.USERDETAILID DESC;
END;
/

-- ===========================================================================
--  SECTION D. TICKET TABLES (with sequences + triggers)
-- ===========================================================================
DECLARE
    v_cnt NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_cnt FROM ALL_SEQUENCES
    WHERE SEQUENCE_OWNER = USER AND SEQUENCE_NAME = 'JB_TICKETS_SEQ';
    IF v_cnt = 0 THEN
        EXECUTE IMMEDIATE 'CREATE SEQUENCE JB_TICKETS_SEQ START WITH 1 INCREMENT BY 1 NOCACHE';
    END IF;

    SELECT COUNT(*) INTO v_cnt FROM ALL_SEQUENCES
    WHERE SEQUENCE_OWNER = USER AND SEQUENCE_NAME = 'JB_TICKET_RESPONSES_SEQ';
    IF v_cnt = 0 THEN
        EXECUTE IMMEDIATE 'CREATE SEQUENCE JB_TICKET_RESPONSES_SEQ START WITH 1 INCREMENT BY 1 NOCACHE';
    END IF;
END;
/

DECLARE
    v_cnt NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_cnt FROM USER_TABLES WHERE TABLE_NAME = 'JB_TICKETS';
    IF v_cnt = 0 THEN
        EXECUTE IMMEDIATE 'CREATE TABLE JB_TICKETS (
            TICKET_ID          NUMBER       CONSTRAINT PK_JB_TICKETS PRIMARY KEY,
            TICKET_REF_NO      VARCHAR2(30) NOT NULL UNIQUE,
            ISSUE_TYPE_ID      NUMBER(2)    NOT NULL,
            ISSUE_TYPE_NAME    VARCHAR2(100) NOT NULL,
            RAISED_BY_USER_ID  NUMBER       NOT NULL,
            RAISED_BY_BANK_ID  VARCHAR2(30) NOT NULL,
            CUSTOMER_NAME      VARCHAR2(200),
            MOBILE_NO          VARCHAR2(20),
            ACCOUNT_NO         VARCHAR2(40),
            REMARKS            VARCHAR2(2000),
            ATTACHMENT_PATH    VARCHAR2(500),
            PRIORITY           VARCHAR2(20) NOT NULL
                               CONSTRAINT CK_JB_TICKET_PRIORITY
                               CHECK (PRIORITY IN (''VERY HIGH'',''HIGH'',''LOW'')),
            STATUS             VARCHAR2(20) DEFAULT ''OPEN'' NOT NULL
                               CONSTRAINT CK_JB_TICKET_STATUS
                               CHECK (STATUS IN (''OPEN'',''IN_PROGRESS'',''SOLVED'',''DENIED'')),
            CREATED_AT         TIMESTAMP    DEFAULT SYSTIMESTAMP NOT NULL,
            SOLVED_AT          TIMESTAMP
        )';
        EXECUTE IMMEDIATE 'CREATE INDEX IDX_JB_TICKET_STATUS  ON JB_TICKETS (STATUS)';
        EXECUTE IMMEDIATE 'CREATE INDEX IDX_JB_TICKET_PRIOR   ON JB_TICKETS (PRIORITY)';
    END IF;

    SELECT COUNT(*) INTO v_cnt FROM USER_TABLES WHERE TABLE_NAME = 'JB_TICKET_RESPONSES';
    IF v_cnt = 0 THEN
        EXECUTE IMMEDIATE 'CREATE TABLE JB_TICKET_RESPONSES (
            RESPONSE_ID        NUMBER      CONSTRAINT PK_JB_TICKET_RESP PRIMARY KEY,
            TICKET_ID          NUMBER      NOT NULL
                               CONSTRAINT FK_JB_RESP_TICKET REFERENCES JB_TICKETS (TICKET_ID),
            RESPONDER_USER_ID  NUMBER      NOT NULL,
            RESPONDER_BANK_ID  VARCHAR2(30),
            ACTION_TAKEN       VARCHAR2(20) NOT NULL
                               CONSTRAINT CK_JB_RESP_ACTION
                               CHECK (ACTION_TAKEN IN (''SOLVED'',''DENIED'',''NOTE'')),
            REMARKS            VARCHAR2(2000),
            CREATED_AT         TIMESTAMP   DEFAULT SYSTIMESTAMP NOT NULL
        )';
        EXECUTE IMMEDIATE 'CREATE INDEX IDX_JB_RESP_TICKET    ON JB_TICKET_RESPONSES (TICKET_ID)';
    END IF;
END;
/

CREATE OR REPLACE TRIGGER TRG_JB_TICKETS_BI
BEFORE INSERT ON JB_TICKETS
FOR EACH ROW
WHEN (NEW.TICKET_ID IS NULL)
BEGIN
   SELECT JB_TICKETS_SEQ.NEXTVAL INTO :NEW.TICKET_ID FROM DUAL;
   :NEW.TICKET_REF_NO := 'TKT-' || TO_CHAR(SYSDATE, 'YYYYMMDD') || '-' || LPAD(:NEW.TICKET_ID, 4, '0');
END;
/

CREATE OR REPLACE TRIGGER TRG_JB_TICKET_RESP_BI
BEFORE INSERT ON JB_TICKET_RESPONSES
FOR EACH ROW
WHEN (NEW.RESPONSE_ID IS NULL)
BEGIN
   SELECT JB_TICKET_RESPONSES_SEQ.NEXTVAL INTO :NEW.RESPONSE_ID FROM DUAL;
END;
/

-- ===========================================================================
--  SECTION E. TICKET PROCEDURES (NO SQL IN VIEWS - ALL HERE)
-- ===========================================================================

-- E1. RAISE A TICKET
CREATE OR REPLACE PROCEDURE SP_RAISE_TICKET (
    p_raised_by_user_id  IN NUMBER,
    p_raised_by_bank_id  IN VARCHAR2,
    p_issue_type_id      IN NUMBER,
    p_issue_type_name    IN VARCHAR2,
    p_customer_name      IN VARCHAR2,
    p_mobile_no          IN VARCHAR2,
    p_account_no         IN VARCHAR2,
    p_remarks            IN VARCHAR2,
    p_attachment_path    IN VARCHAR2,
    p_priority           IN VARCHAR2,
    o_ticket_id          OUT NUMBER,
    o_ticket_ref         OUT VARCHAR2,
    o_success            OUT NUMBER,
    o_msg                OUT VARCHAR2
) AS
    v_ticket_id NUMBER;
BEGIN
    o_success := 0;

    IF p_priority NOT IN ('VERY HIGH','HIGH','LOW') THEN
        o_msg := 'Invalid priority.';
        RETURN;
    END IF;

    IF p_issue_type_id IS NULL THEN
        o_msg := 'Select an issue type.';
        RETURN;
    END IF;

    IF p_mobile_no IS NULL AND p_account_no IS NULL THEN
        o_msg := 'Provide at least Mobile No or Account No.';
        RETURN;
    END IF;

    INSERT INTO JB_TICKETS (
        ISSUE_TYPE_ID, ISSUE_TYPE_NAME,
        RAISED_BY_USER_ID, RAISED_BY_BANK_ID,
        CUSTOMER_NAME, MOBILE_NO, ACCOUNT_NO, REMARKS, ATTACHMENT_PATH,
        PRIORITY
    ) VALUES (
        p_issue_type_id, p_issue_type_name,
        p_raised_by_user_id, p_raised_by_bank_id,
        p_customer_name, p_mobile_no, p_account_no, p_remarks, p_attachment_path,
        p_priority
    )
    RETURNING TICKET_ID INTO v_ticket_id;

    o_ticket_id  := v_ticket_id;
    o_ticket_ref := 'TKT-' || TO_CHAR(SYSDATE, 'YYYYMMDD') || '-' || LPAD(v_ticket_id, 4, '0');
    o_success    := 1;
    o_msg        := 'Ticket raised.';
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        o_success := 0;
        o_msg     := SQLERRM;
END;
/

-- E2. TICKET LIST WITH LATEST / HIGH-PRIORITY FILTER
-- Column order MUST match Django:
-- ticket_id, ticket_ref, issue_type, customer_name, mobile_no, account_no,
-- priority, status, raised_by_bank_id, created_at, response_count, open_days
CREATE OR REPLACE PROCEDURE SP_GET_TICKETS (
    p_filter     IN VARCHAR2 DEFAULT 'LATEST',
    p_out_cursor OUT SYS_REFCURSOR
) AS
BEGIN
    IF UPPER(NVL(p_filter, 'LATEST')) = 'PRIORITY' THEN
        OPEN p_out_cursor FOR
            SELECT t.TICKET_ID,
                   t.TICKET_REF_NO,
                   t.ISSUE_TYPE_NAME,
                   t.CUSTOMER_NAME,
                   t.MOBILE_NO,
                   t.ACCOUNT_NO,
                   t.PRIORITY,
                   t.STATUS,
                   t.RAISED_BY_BANK_ID,
                   t.CREATED_AT,
                   (SELECT COUNT(*) FROM JB_TICKET_RESPONSES r
                     WHERE r.TICKET_ID = t.TICKET_ID) AS RESPONSE_COUNT,
                   CASE WHEN t.STATUS IN ('SOLVED','DENIED') THEN NULL
                        ELSE ROUND(SYSDATE - CAST(t.CREATED_AT AS DATE)) END AS OPEN_DAYS
            FROM   JB_TICKETS t
            ORDER  BY CASE t.PRIORITY
                         WHEN 'VERY HIGH' THEN 1
                         WHEN 'HIGH'      THEN 2
                         ELSE 3
                      END,
                      t.CREATED_AT DESC;
    ELSE
        OPEN p_out_cursor FOR
            SELECT t.TICKET_ID,
                   t.TICKET_REF_NO,
                   t.ISSUE_TYPE_NAME,
                   t.CUSTOMER_NAME,
                   t.MOBILE_NO,
                   t.ACCOUNT_NO,
                   t.PRIORITY,
                   t.STATUS,
                   t.RAISED_BY_BANK_ID,
                   t.CREATED_AT,
                   (SELECT COUNT(*) FROM JB_TICKET_RESPONSES r
                     WHERE r.TICKET_ID = t.TICKET_ID) AS RESPONSE_COUNT,
                   CASE WHEN t.STATUS IN ('SOLVED','DENIED') THEN NULL
                        ELSE ROUND(SYSDATE - CAST(t.CREATED_AT AS DATE)) END AS OPEN_DAYS
            FROM   JB_TICKETS t
            ORDER  BY t.CREATED_AT DESC;
    END IF;
END;
/

-- E3. TICKET DETAIL (header + response thread)
-- NOTE: kept as two separate single-cursor procedures. python-oracledb (thin)
-- hangs when a callproc returns MULTIPLE OUT SYS_REFCURSOR vars together, and
-- also when the FIRST bind of such a call is a NUMBER. The Django app therefore
-- passes TICKET_ID as a string and calls these one cursor at a time.
CREATE OR REPLACE PROCEDURE SP_GET_TICKET_BY_ID (
    p_ticket_id     IN NUMBER,
    o_ticket_cursor OUT SYS_REFCURSOR
) AS
BEGIN
    OPEN o_ticket_cursor FOR
        'SELECT TICKET_ID, TICKET_REF_NO, ISSUE_TYPE_NAME,
                CUSTOMER_NAME, MOBILE_NO, ACCOUNT_NO,
                REMARKS, ATTACHMENT_PATH, PRIORITY, STATUS,
                RAISED_BY_BANK_ID, CREATED_AT
         FROM   JB_TICKETS
         WHERE  TICKET_ID = :b'
        USING p_ticket_id;
END;
/

CREATE OR REPLACE PROCEDURE SP_GET_TICKET_RESPONSES (
    p_ticket_id     IN NUMBER,
    o_response_cur  OUT SYS_REFCURSOR
) AS
BEGIN
    OPEN o_response_cur FOR
        'SELECT RESPONDER_BANK_ID,
                ACTION_TAKEN,
                REMARKS,
                CREATED_AT
         FROM   JB_TICKET_RESPONSES
         WHERE  TICKET_ID = :b
         ORDER  BY CREATED_AT ASC'
        USING p_ticket_id;
END;
/

-- E4. RESPOND / SOLVE / DENY A TICKET
CREATE OR REPLACE PROCEDURE SP_RESPOND_TICKET (
    p_ticket_id         IN NUMBER,
    p_responder_user_id IN NUMBER,
    p_responder_bank_id IN VARCHAR2,
    p_action            IN VARCHAR2,
    p_remarks           IN VARCHAR2,
    o_success           OUT NUMBER,
    o_msg               OUT VARCHAR2
) AS
    v_status VARCHAR2(20);
BEGIN
    o_success := 0;

    IF p_action NOT IN ('SOLVED','DENIED','NOTE') THEN
        o_msg := 'Invalid action.';
        RETURN;
    END IF;

    IF TRIM(NVL(p_remarks, ' ')) IS NULL THEN
        o_msg := 'Remarks are required before responding.';
        RETURN;
    END IF;

    BEGIN
        SELECT STATUS INTO v_status
        FROM   JB_TICKETS
        WHERE  TICKET_ID = p_ticket_id
        FOR UPDATE;

        IF NVL(v_status, 'CLOSED') IN ('SOLVED','DENIED') AND p_action IN ('SOLVED','DENIED') THEN
            o_msg := 'This ticket is already closed.';
            RETURN;
        END IF;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            o_msg := 'Ticket not found.';
            RETURN;
    END;

    INSERT INTO JB_TICKET_RESPONSES (
        RESPONSE_ID, TICKET_ID,
        RESPONDER_USER_ID, RESPONDER_BANK_ID,
        ACTION_TAKEN, REMARKS
    ) VALUES (
        JB_TICKET_RESPONSES_SEQ.NEXTVAL, p_ticket_id,
        p_responder_user_id, p_responder_bank_id,
        p_action, TRIM(p_remarks)
    );

    IF p_action = 'SOLVED' THEN
        UPDATE JB_TICKETS SET STATUS = 'SOLVED', SOLVED_AT = SYSTIMESTAMP
        WHERE TICKET_ID = p_ticket_id;
    ELSIF p_action = 'DENIED' THEN
        UPDATE JB_TICKETS SET STATUS = 'DENIED', SOLVED_AT = SYSTIMESTAMP
        WHERE TICKET_ID = p_ticket_id;
    ELSE
        IF v_status = 'OPEN' THEN
            UPDATE JB_TICKETS SET STATUS = 'IN_PROGRESS'
            WHERE TICKET_ID = p_ticket_id;
        END IF;
    END IF;

    o_success := 1;
    o_msg     := 'Response recorded.';
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        o_success := 0;
        o_msg     := SQLERRM;
END;
/

-- ===========================================================================
--  SECTION F. MENU REGISTRATION
--  Adds the ticket menus and grants them (plus the existing menus) to the
--  Manager and normal User roles so every logged-in role can use the portal.
--  NOTE: SYSTEM_MENU.MENU_ID is GENERATED ALWAYS AS IDENTITY, so we insert
--  without it and capture the generated id via RETURNING.
-- ===========================================================================
DECLARE
    v_mid NUMBER;
BEGIN
    -- 'Raise Ticket'
    BEGIN
        SELECT MENU_ID INTO v_mid FROM SYSTEM_MENU WHERE URL_NAME = 'raise_ticket';
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            INSERT INTO SYSTEM_MENU (MENU_TITLE, URL_NAME, PARENT_ID, ICON_CLASS, DISPLAY_ORDER)
            VALUES ('Raise Ticket', 'raise_ticket', NULL, 'bi-plus-circle', 7)
            RETURNING MENU_ID INTO v_mid;
    END;

    -- 'Tickets'
    BEGIN
        SELECT MENU_ID INTO v_mid FROM SYSTEM_MENU WHERE URL_NAME = 'tickets';
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            INSERT INTO SYSTEM_MENU (MENU_TITLE, URL_NAME, PARENT_ID, ICON_CLASS, DISPLAY_ORDER)
            VALUES ('Tickets', 'tickets', NULL, 'bi-ticket-perforated', 8)
            RETURNING MENU_ID INTO v_mid;
    END;

    -- Grant all existing + new menus to Superadmin (1)
    INSERT INTO ROLE_MENU_PERMISSION (ROLE_ID, MENU_ID)
        SELECT 1, MENU_ID FROM SYSTEM_MENU m
        WHERE NOT EXISTS (SELECT 1 FROM ROLE_MENU_PERMISSION rmp
                           WHERE rmp.ROLE_ID = 1 AND rmp.MENU_ID = m.MENU_ID);

    -- Grant Manager (2): Dashboard, Manager Dashboard, Pending Registration,
    -- Audit Trail, Change Password, Raise Ticket, Tickets
    INSERT INTO ROLE_MENU_PERMISSION (ROLE_ID, MENU_ID)
        SELECT 2, MENU_ID FROM SYSTEM_MENU m
        WHERE m.URL_NAME IN ('dashboard','manager_dashboard','pending_registration',
                             'audit_trail','change_password','raise_ticket','tickets')
          AND NOT EXISTS (SELECT 1 FROM ROLE_MENU_PERMISSION rmp
                           WHERE rmp.ROLE_ID = 2 AND rmp.MENU_ID = m.MENU_ID);

    -- Grant normal User (3): Dashboard, Change Password, Raise Ticket, Tickets
    INSERT INTO ROLE_MENU_PERMISSION (ROLE_ID, MENU_ID)
        SELECT 3, MENU_ID FROM SYSTEM_MENU m
        WHERE m.URL_NAME IN ('dashboard','change_password','raise_ticket','tickets')
          AND NOT EXISTS (SELECT 1 FROM ROLE_MENU_PERMISSION rmp
                           WHERE rmp.ROLE_ID = 3 AND rmp.MENU_ID = m.MENU_ID);

    COMMIT;
END;
/

-- ============================================================
--  All objects created/updated successfully.
--  Test login -> Raise Ticket (Tickets menu) -> View -> Solve.
-- ============================================================