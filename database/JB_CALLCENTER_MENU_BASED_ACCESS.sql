-- ===========================================================================
--  *** SUPERSEDED - DO NOT USE ***
--  This legacy patch has been folded into:
--    - JB_CALLCENTER_SETUP.sql      (brand-new install, no triggers/sequences)
--    - JB_CALLCENTER_MIGRATION_NO_TRIGGER_SEQUENCE.sql  (upgrade of existing DB)
--  Use one of those two files instead of this one.
-- ===========================================================================
--  JB CALL CENTER - MENU-BASED ACCESS PERMISSIONS
-- ---------------------------------------------------------------------------
--  Run as the JBCALLCENTER schema user (the same user Django connects with).
--  Idempotent - safe to re-run any number of times.
--
--  WHAT THIS SCRIPT DOES
--  ----------------------------------------------------------------------
--  1. Creates USER_MENU_ASSIGNMENT - the per-user menu table. Access is now
--     granted directly to each user (menu-based), instead of through roles.
--     ROLE_MENU_PERMISSION is retained only as a one-time migration source.
--
--  2. Adds the 'Bank Support' role. Only users whose ROLE_NAME is
--     'Bank Support' can take action (solve / deny / note) on tickets.
--     The role itself can only be assigned by the Superadmin.
--
--  3. Migrates every existing user's current role-based menus into their
--     personal USER_MENU_ASSIGNMENT rows, so nobody loses access.
--
--  4. Renames the old 'Assign Role' menu to 'Assign Menu' (assign_menu).
--
--  5. Replaces the access SPs so they read per-user assignments:
--       SP_GET_USER_MENUS          (sidebar - per-user rows)
--       SP_CHECK_USER_MENU_ACCESS  (per-user rows)
--       SP_APPROVE_REGISTRATION    (new users get ONLY Dashboard + Change Password)
--       SP_CREATE_MANAGER_BY_SUPERADMIN (new managers get the manager menu set)
--       SP_RESPOND_TICKET          (only Bank Support may respond)
--
--  6. Creates the Assign Menu panel SPs:
--       SP_GET_ASSIGNABLE_MENUS    (menus the actor may grant = his own menus)
--       SP_GET_MENU_ASSIGN_USERS   (users the actor may manage)
--       SP_SET_USER_MENU_ACCESS    (assign / remove a menu for a user)
--       SP_ASSIGN_BANK_SUPPORT_ROLE (Superadmin-only Bank Support role toggle)
--
--  7. Drops the obsolete role-assignment procedures.
-- ===========================================================================

WHENEVER SQLERROR CONTINUE
/

-- ===========================================================================
-- 1. USER_MENU_ASSIGNMENT TABLE
-- ===========================================================================
DECLARE
    v_cnt NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_cnt FROM USER_TABLES WHERE TABLE_NAME = 'USER_MENU_ASSIGNMENT';
    IF v_cnt = 0 THEN
        EXECUTE IMMEDIATE 'CREATE TABLE USER_MENU_ASSIGNMENT (
            USERDETAILID      NUMBER NOT NULL,
            MENU_ID           NUMBER NOT NULL,
            ASSIGNED_BY_USER_ID NUMBER,
            ASSIGNED_AT       TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
            CONSTRAINT PK_USER_MENU_ASSIGNMENT PRIMARY KEY (USERDETAILID, MENU_ID)
        )';
        EXECUTE IMMEDIATE 'CREATE INDEX IDX_UMA_MENU ON USER_MENU_ASSIGNMENT (MENU_ID)';
    END IF;
END;
/

-- ===========================================================================
-- 2. BANK SUPPORT ROLE
-- ===========================================================================
DECLARE
    v_cnt NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_cnt FROM SYSTEM_ROLE WHERE UPPER(ROLE_NAME) = 'BANK SUPPORT';
    IF v_cnt = 0 THEN
        INSERT INTO SYSTEM_ROLE (ROLE_NAME, DESCRIPTION)
        VALUES ('Bank Support', 'Resolves and takes action on support tickets.');
    END IF;
    COMMIT;
END;
/

-- ===========================================================================
-- 3. MIGRATE EXISTING ROLE-BASED MENUS INTO PER-USER ASSIGNMENTS
-- ===========================================================================
INSERT INTO USER_MENU_ASSIGNMENT (USERDETAILID, MENU_ID, ASSIGNED_BY_USER_ID, ASSIGNED_AT)
SELECT DISTINCT u.USERDETAILID, rmp.MENU_ID, NULL, CURRENT_TIMESTAMP
  FROM USERDETAIL u
  JOIN ROLE_MENU_PERMISSION rmp ON u.ROLE_ID = rmp.ROLE_ID
 WHERE NOT EXISTS (
     SELECT 1 FROM USER_MENU_ASSIGNMENT x
      WHERE x.USERDETAILID = u.USERDETAILID AND x.MENU_ID = rmp.MENU_ID
 );
COMMIT;

-- Superadmin always holds every menu (in case a menu was added without a grant).
INSERT INTO USER_MENU_ASSIGNMENT (USERDETAILID, MENU_ID, ASSIGNED_BY_USER_ID, ASSIGNED_AT)
SELECT u.USERDETAILID, m.MENU_ID, NULL, CURRENT_TIMESTAMP
  FROM USERDETAIL u
  JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
 CROSS JOIN SYSTEM_MENU m
 WHERE UPPER(r.ROLE_NAME) = 'SUPERADMIN'
   AND NOT EXISTS (
       SELECT 1 FROM USER_MENU_ASSIGNMENT x
        WHERE x.USERDETAILID = u.USERDETAILID AND x.MENU_ID = m.MENU_ID
   );
COMMIT;

-- ===========================================================================
-- 4. RENAME 'ASSIGN ROLE' MENU -> 'ASSIGN MENU'
-- ===========================================================================
UPDATE SYSTEM_MENU
   SET MENU_TITLE = 'Assign Menu', URL_NAME = 'assign_menu'
 WHERE URL_NAME = 'assign_role';
COMMIT;

DECLARE
    v_mid NUMBER;
BEGIN
    BEGIN
        SELECT MENU_ID INTO v_mid FROM SYSTEM_MENU WHERE URL_NAME = 'assign_menu';
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            INSERT INTO SYSTEM_MENU (MENU_TITLE, URL_NAME, PARENT_ID, ICON_CLASS, DISPLAY_ORDER)
            VALUES ('Assign Menu', 'assign_menu', NULL, 'bi-person-badge', 4)
            RETURNING MENU_ID INTO v_mid;

            -- Give the brand-new menu to Superadmin + existing Managers.
            INSERT INTO USER_MENU_ASSIGNMENT (USERDETAILID, MENU_ID, ASSIGNED_BY_USER_ID, ASSIGNED_AT)
            SELECT u.USERDETAILID, v_mid, NULL, CURRENT_TIMESTAMP
              FROM USERDETAIL u
              JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
             WHERE UPPER(r.ROLE_NAME) IN ('SUPERADMIN','MANAGER')
               AND NOT EXISTS (
                   SELECT 1 FROM USER_MENU_ASSIGNMENT x
                    WHERE x.USERDETAILID = u.USERDETAILID AND x.MENU_ID = v_mid
               );
    END;
    COMMIT;
END;
/

-- ===========================================================================
-- 5a. SP_GET_USER_MENUS - PER-USER (sidebar)
-- ===========================================================================
CREATE OR REPLACE PROCEDURE SP_GET_USER_MENUS (
    p_user_id      IN  NUMBER,
    p_menu_cursor  OUT SYS_REFCURSOR
) AS
BEGIN
    OPEN p_menu_cursor FOR
        SELECT m.MENU_ID,
               m.MENU_TITLE,
               m.URL_NAME,
               m.PARENT_ID,
               m.ICON_CLASS
          FROM USER_MENU_ASSIGNMENT uma
          JOIN SYSTEM_MENU m ON uma.MENU_ID = m.MENU_ID
         WHERE uma.USERDETAILID = p_user_id
      ORDER BY m.PARENT_ID NULLS FIRST, m.DISPLAY_ORDER ASC;
END;
/

-- ===========================================================================
-- 5b. SP_CHECK_USER_MENU_ACCESS - PER-USER
-- ===========================================================================
CREATE OR REPLACE PROCEDURE SP_CHECK_USER_MENU_ACCESS (
    p_user_id    IN NUMBER,
    p_url_name   IN VARCHAR2,
    p_has_access OUT NUMBER
) AS
    v_count NUMBER := 0;
BEGIN
    SELECT COUNT(1) INTO v_count
      FROM SYSTEM_MENU m
      JOIN USER_MENU_ASSIGNMENT uma ON m.MENU_ID = uma.MENU_ID
     WHERE uma.USERDETAILID = p_user_id
       AND TRIM(UPPER(m.URL_NAME)) = TRIM(UPPER(NVL(p_url_name, '')));

    IF v_count > 0 THEN
        p_has_access := 1;
    ELSE
        p_has_access := 0;
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        p_has_access := 0;
END;
/

-- ===========================================================================
-- 5c. SP_APPROVE_REGISTRATION - NEW USER GETS ONLY DASHBOARD + CHANGE PASSWORD
-- ===========================================================================
CREATE OR REPLACE PROCEDURE SP_APPROVE_REGISTRATION (
    p_reg_id IN NUMBER,
    p_temp_password IN VARCHAR2,
    p_manager_user_id IN NUMBER,
    p_gen_bank_id OUT VARCHAR2,
    p_user_email OUT VARCHAR2,
    p_success OUT NUMBER,
    p_msg OUT VARCHAR2
) AS
    v_fullname VARCHAR2(100);
    v_mobile   VARCHAR2(20);
    v_email    VARCHAR2(100);
    v_nid      VARCHAR2(30);
    v_attach   VARCHAR2(255);
    v_user_role_id NUMBER;
    v_manager_role VARCHAR2(50);
    v_new_user_id  NUMBER;
BEGIN
    SELECT UPPER(r.ROLE_NAME) INTO v_manager_role
    FROM USERDETAIL u
    JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
    WHERE u.USERDETAILID = p_manager_user_id;

    IF v_manager_role NOT IN ('MANAGER', 'SUPERADMIN') THEN
        p_success := 0;
        p_msg     := 'Access Denied: Only Manager or Superadmin can approve users.';
        RETURN;
    END IF;

    SELECT ROLE_ID INTO v_user_role_id FROM SYSTEM_ROLE WHERE UPPER(ROLE_NAME) = 'USER';

    SELECT FULLNAME, MOBILE_NO, EMAIL, NID, ATTACHMENT_PATH
    INTO v_fullname, v_mobile, v_email, v_nid, v_attach
    FROM USER_REGISTRATION
    WHERE REGISTRATION_ID = p_reg_id AND STATUS = 'PENDING';

    p_gen_bank_id := 'JB' || SEQ_BANK_ID.NEXTVAL;
    p_user_email  := v_email;

    INSERT INTO USERDETAIL (
        BANKID, FULLNAME, MOBILE_NO, EMAIL, NID, ATTACHMENT_PATH,
        USERPASSWORD, ROLE_ID, IS_FIRST_LOGIN, USERSTATUS, FAILED_ATTEMPTS,
        APPROVED_BY_USER_ID, APPROVED_AT
    ) VALUES (
        p_gen_bank_id, v_fullname, v_mobile, v_email, v_nid, v_attach,
        p_temp_password, v_user_role_id, 1, 'Enabled', 0,
        p_manager_user_id, CURRENT_TIMESTAMP
    ) RETURNING USERDETAILID INTO v_new_user_id;

    -- Default menu grants: a newly approved user starts with ONLY
    -- Dashboard + Change Password. More menus are added via Assign Menu.
    FOR mc IN (
        SELECT MENU_ID FROM SYSTEM_MENU
        WHERE URL_NAME IN ('dashboard', 'change_password')
    ) LOOP
        INSERT INTO USER_MENU_ASSIGNMENT (USERDETAILID, MENU_ID, ASSIGNED_BY_USER_ID, ASSIGNED_AT)
        VALUES (v_new_user_id, mc.MENU_ID, p_manager_user_id, CURRENT_TIMESTAMP);
    END LOOP;

    UPDATE USER_REGISTRATION SET STATUS = 'APPROVED' WHERE REGISTRATION_ID = p_reg_id;

    p_success := 1;
    p_msg     := 'User approved successfully.';
    COMMIT;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        p_success := 0;
        p_msg     := 'Registration record or role definition missing.';
    WHEN OTHERS THEN
        p_success := 0;
        p_msg     := SQLERRM;
END;
/

-- ===========================================================================
-- 5d. SP_CREATE_MANAGER_BY_SUPERADMIN - NEW MANAGER GETS THE MANAGER MENU SET
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
    v_new_user_id NUMBER;
BEGIN
    SELECT UPPER(r.ROLE_NAME) INTO v_superadmin_role
    FROM USERDETAIL u
    JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
    WHERE u.USERDETAILID = p_superadmin_user_id;

    IF v_superadmin_role != 'SUPERADMIN' THEN
        p_success := 0;
        p_msg     := 'Access Denied: Only Superadmin can create Manager accounts.';
        RETURN;
    END IF;

    SELECT ROLE_ID INTO v_role_id FROM SYSTEM_ROLE WHERE UPPER(ROLE_NAME) = 'MANAGER';

    p_gen_bank_id := 'MGR' || SEQ_BANK_ID.NEXTVAL;

    INSERT INTO USERDETAIL (
        BANKID, FULLNAME, MOBILE_NO, EMAIL, NID, IMAGE_PATH, USERPASSWORD,
        ROLE_ID, IS_FIRST_LOGIN, USERSTATUS, APPROVED_BY_USER_ID, APPROVED_AT
    ) VALUES (
        p_gen_bank_id, p_fullname, p_mobile, p_email, p_nid, p_image_path, p_temp_password,
        v_role_id, 1, 'Enabled', p_superadmin_user_id, CURRENT_TIMESTAMP
    ) RETURNING USERDETAILID INTO v_new_user_id;

    -- Standard manager menu set (fine-tuned later via Assign Menu).
    FOR mc IN (
        SELECT MENU_ID FROM SYSTEM_MENU
        WHERE URL_NAME IN (
            'dashboard', 'manager_dashboard', 'pending_registration',
            'user_unlock', 'assign_menu', 'approve_user', 'unlock_user',
            'audit_trail', 'change_password', 'raise_ticket', 'tickets'
        )
    ) LOOP
        INSERT INTO USER_MENU_ASSIGNMENT (USERDETAILID, MENU_ID, ASSIGNED_BY_USER_ID, ASSIGNED_AT)
        VALUES (v_new_user_id, mc.MENU_ID, p_superadmin_user_id, CURRENT_TIMESTAMP);
    END LOOP;

    p_success := 1;
    p_msg     := 'Manager account created successfully.';
    COMMIT;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        p_success := 0;
        p_msg     := 'Superadmin or Manager role definition missing.';
    WHEN OTHERS THEN
        p_success := 0;
        p_msg     := SQLERRM;
END;
/

-- ===========================================================================
-- 5e. SP_RESPOND_TICKET - ONLY BANK SUPPORT MAY TAKE ACTION
-- ===========================================================================
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
    v_responder_role VARCHAR2(50);
BEGIN
    o_success := 0;

    -- Bank Support gate
    SELECT UPPER(NVL(r.ROLE_NAME, ''))
      INTO v_responder_role
      FROM USERDETAIL u
      LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
     WHERE u.USERDETAILID = p_responder_user_id;

    IF v_responder_role <> 'BANK SUPPORT' THEN
        o_msg := 'Access Denied: Only Bank Support users can take action on tickets.';
        RETURN;
    END IF;

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
    WHEN NO_DATA_FOUND THEN
        o_msg := 'Responder not found.';
    WHEN OTHERS THEN
        o_success := 0;
        o_msg     := SQLERRM;
END;
/

-- ===========================================================================
-- 6a. SP_GET_ASSIGNABLE_MENUS - MENUS THE ACTOR MAY GRANT (HIS OWN TOP-LEVEL)
-- Column order: menu_id, menu_title, url_name, icon_class
-- ===========================================================================
CREATE OR REPLACE PROCEDURE SP_GET_ASSIGNABLE_MENUS (
    p_actor_user_id IN NUMBER,
    o_cursor        OUT SYS_REFCURSOR
) AS
BEGIN
    OPEN o_cursor FOR
        SELECT m.MENU_ID,
               m.MENU_TITLE,
               m.URL_NAME,
               NVL(m.ICON_CLASS, '')
          FROM USER_MENU_ASSIGNMENT uma
          JOIN SYSTEM_MENU m ON uma.MENU_ID = m.MENU_ID
         WHERE uma.USERDETAILID = p_actor_user_id
           AND m.PARENT_ID IS NULL
         ORDER BY m.DISPLAY_ORDER, m.MENU_TITLE;
END;
/

-- ===========================================================================
-- 6b. SP_GET_MENU_ASSIGN_USERS - USERS THE ACTOR MAY MANAGE
--      Superadmin : every user except himself (Manager / User / Bank Support)
--      Manager    : regular 'User' accounts only (never Support / Manager / Superadmin)
-- Columns: bank_id, user_id, fullname, email, status, role_name, role_id,
--          menu_ids (csv), menu_titles (pipe-separated)
-- ===========================================================================
CREATE OR REPLACE PROCEDURE SP_GET_MENU_ASSIGN_USERS (
    p_actor_user_id IN NUMBER,
    o_cursor        OUT SYS_REFCURSOR
) AS
    v_actor_role VARCHAR2(50);
BEGIN
    SELECT UPPER(NVL(r.ROLE_NAME, ''))
      INTO v_actor_role
      FROM USERDETAIL u
      LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
     WHERE u.USERDETAILID = p_actor_user_id;

    IF v_actor_role = 'SUPERADMIN' THEN
        OPEN o_cursor FOR
            SELECT u.BANKID,
                   u.USERDETAILID,
                   u.FULLNAME,
                   u.EMAIL,
                   u.USERSTATUS,
                   NVL(r.ROLE_NAME, 'No Role'),
                   NVL(u.ROLE_ID, 0),
                   (SELECT LISTAGG(m2.MENU_ID, ',') WITHIN GROUP (ORDER BY m2.DISPLAY_ORDER, m2.MENU_ID)
                      FROM USER_MENU_ASSIGNMENT a
                      JOIN SYSTEM_MENU m2 ON a.MENU_ID = m2.MENU_ID
                     WHERE a.USERDETAILID = u.USERDETAILID
                       AND m2.PARENT_ID IS NULL) AS MENU_IDS,
                   (SELECT LISTAGG(m2.MENU_TITLE, '|') WITHIN GROUP (ORDER BY m2.DISPLAY_ORDER, m2.MENU_ID)
                      FROM USER_MENU_ASSIGNMENT a
                      JOIN SYSTEM_MENU m2 ON a.MENU_ID = m2.MENU_ID
                     WHERE a.USERDETAILID = u.USERDETAILID
                       AND m2.PARENT_ID IS NULL) AS MENU_TITLES
              FROM USERDETAIL u
              LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
             WHERE u.USERDETAILID <> p_actor_user_id
             ORDER BY u.FULLNAME;
    ELSIF v_actor_role = 'MANAGER' THEN
        OPEN o_cursor FOR
            SELECT u.BANKID,
                   u.USERDETAILID,
                   u.FULLNAME,
                   u.EMAIL,
                   u.USERSTATUS,
                   NVL(r.ROLE_NAME, 'No Role'),
                   NVL(u.ROLE_ID, 0),
                   (SELECT LISTAGG(m2.MENU_ID, ',') WITHIN GROUP (ORDER BY m2.DISPLAY_ORDER, m2.MENU_ID)
                      FROM USER_MENU_ASSIGNMENT a
                      JOIN SYSTEM_MENU m2 ON a.MENU_ID = m2.MENU_ID
                     WHERE a.USERDETAILID = u.USERDETAILID
                       AND m2.PARENT_ID IS NULL) AS MENU_IDS,
                   (SELECT LISTAGG(m2.MENU_TITLE, '|') WITHIN GROUP (ORDER BY m2.DISPLAY_ORDER, m2.MENU_ID)
                      FROM USER_MENU_ASSIGNMENT a
                      JOIN SYSTEM_MENU m2 ON a.MENU_ID = m2.MENU_ID
                     WHERE a.USERDETAILID = u.USERDETAILID
                       AND m2.PARENT_ID IS NULL) AS MENU_TITLES
              FROM USERDETAIL u
              LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
             WHERE UPPER(NVL(r.ROLE_NAME, '')) = 'USER'
             ORDER BY u.FULLNAME;
    ELSE
        OPEN o_cursor FOR
            SELECT CAST(NULL AS VARCHAR2(30)),
                   CAST(NULL AS NUMBER),
                   CAST(NULL AS VARCHAR2(100)),
                   CAST(NULL AS VARCHAR2(100)),
                   CAST(NULL AS VARCHAR2(20)),
                   CAST(NULL AS VARCHAR2(50)),
                   CAST(NULL AS NUMBER),
                   CAST(NULL AS VARCHAR2(4000)),
                   CAST(NULL AS VARCHAR2(4000))
              FROM DUAL
             WHERE 1 = 0;
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        OPEN o_cursor FOR
            SELECT CAST(NULL AS VARCHAR2(30)),
                   CAST(NULL AS NUMBER),
                   CAST(NULL AS VARCHAR2(100)),
                   CAST(NULL AS VARCHAR2(100)),
                   CAST(NULL AS VARCHAR2(20)),
                   CAST(NULL AS VARCHAR2(50)),
                   CAST(NULL AS NUMBER),
                   CAST(NULL AS VARCHAR2(4000)),
                   CAST(NULL AS VARCHAR2(4000))
              FROM DUAL
             WHERE 1 = 0;
END;
/

-- ===========================================================================
-- 6c. SP_SET_USER_MENU_ACCESS - ASSIGN / REMOVE A MENU FOR A USER
-- ===========================================================================
CREATE OR REPLACE PROCEDURE SP_SET_USER_MENU_ACCESS (
    p_actor_user_id  IN NUMBER,
    p_target_bank_id IN VARCHAR2,
    p_menu_id        IN NUMBER,
    p_enable         IN NUMBER,
    p_success        OUT NUMBER,
    p_msg            OUT VARCHAR2
) AS
    v_actor_role  VARCHAR2(50);
    v_target_id   NUMBER;
    v_target_role VARCHAR2(50) := '';
    v_menu_count  NUMBER;
    v_cnt         NUMBER;
    v_menu_title  VARCHAR2(100);
BEGIN
    p_success := 0;

    -- actor identity
    SELECT UPPER(NVL(r.ROLE_NAME, ''))
      INTO v_actor_role
      FROM USERDETAIL u
      LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
     WHERE u.USERDETAILID = p_actor_user_id;

    IF v_actor_role NOT IN ('SUPERADMIN', 'MANAGER') THEN
        p_msg := 'Access Denied: Only Superadmin or Manager can change menu access.';
        RETURN;
    END IF;

    -- target
    BEGIN
        SELECT u.USERDETAILID, UPPER(NVL(r.ROLE_NAME, ''))
          INTO v_target_id, v_target_role
          FROM USERDETAIL u
          LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
         WHERE u.BANKID = p_target_bank_id;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            p_msg := 'Target user not found.';
            RETURN;
    END;

    IF v_target_id = p_actor_user_id THEN
        p_msg := 'You cannot change your own menu access.';
        RETURN;
    END IF;

    -- Manager may only manage regular Users
    IF v_actor_role = 'MANAGER' AND v_target_role <> 'USER' THEN
        p_msg := 'Access Denied: Managers can only assign menus to regular users.';
        RETURN;
    END IF;

    -- menu must exist
    SELECT MENU_TITLE INTO v_menu_title
      FROM SYSTEM_MENU
     WHERE MENU_ID = p_menu_id;

    -- actor must already hold the menu (assignable pool = the actor's own menus)
    SELECT COUNT(1) INTO v_cnt
      FROM USER_MENU_ASSIGNMENT
     WHERE USERDETAILID = p_actor_user_id AND MENU_ID = p_menu_id;

    IF v_cnt = 0 THEN
        p_msg := 'Access Denied: You may only grant menus that are assigned to you.';
        RETURN;
    END IF;

    SELECT COUNT(1) INTO v_menu_count
      FROM USER_MENU_ASSIGNMENT
     WHERE USERDETAILID = v_target_id AND MENU_ID = p_menu_id;

    IF p_enable = 1 THEN
        IF v_menu_count > 0 THEN
            p_msg := 'Menu already assigned to the user.';
            RETURN;
        END IF;
        INSERT INTO USER_MENU_ASSIGNMENT (USERDETAILID, MENU_ID, ASSIGNED_BY_USER_ID, ASSIGNED_AT)
        VALUES (v_target_id, p_menu_id, p_actor_user_id, CURRENT_TIMESTAMP);
        p_msg := 'Menu "' || v_menu_title || '" assigned to ' || p_target_bank_id || '.';
    ELSE
        IF v_menu_count = 0 THEN
            p_msg := 'Menu is not assigned to the user.';
            RETURN;
        END IF;
        DELETE FROM USER_MENU_ASSIGNMENT
         WHERE USERDETAILID = v_target_id AND MENU_ID = p_menu_id;
        p_msg := 'Menu "' || v_menu_title || '" removed from ' || p_target_bank_id || '.';
    END IF;

    p_success := 1;
    COMMIT;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        p_success := 0;
        p_msg     := 'Menu not found.';
    WHEN OTHERS THEN
        p_success := 0;
        p_msg     := SQLERRM;
END;
/

-- ===========================================================================
-- 6d. SP_ASSIGN_BANK_SUPPORT_ROLE - SUPERADMIN-ONLY TOGGLE
--      p_enable = 1 -> make the user Bank Support (from a regular User)
--      p_enable = 0 -> revert them to a regular User
-- ===========================================================================
CREATE OR REPLACE PROCEDURE SP_ASSIGN_BANK_SUPPORT_ROLE (
    p_actor_user_id  IN NUMBER,
    p_target_bank_id IN VARCHAR2,
    p_enable         IN NUMBER,
    p_success        OUT NUMBER,
    p_msg            OUT VARCHAR2
) AS
    v_actor_role   VARCHAR2(50);
    v_target_id    NUMBER;
    v_target_role  VARCHAR2(50) := '';
    v_support_role_id NUMBER;
    v_user_role_id NUMBER;
BEGIN
    p_success := 0;

    SELECT UPPER(NVL(r.ROLE_NAME, ''))
      INTO v_actor_role
      FROM USERDETAIL u
      LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
     WHERE u.USERDETAILID = p_actor_user_id;

    IF v_actor_role <> 'SUPERADMIN' THEN
        p_msg := 'Access Denied: Only Superadmin can assign the Bank Support role.';
        RETURN;
    END IF;

    BEGIN
        SELECT u.USERDETAILID, UPPER(NVL(r.ROLE_NAME, ''))
          INTO v_target_id, v_target_role
          FROM USERDETAIL u
          LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
         WHERE u.BANKID = p_target_bank_id;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            p_msg := 'Target user not found.';
            RETURN;
    END;

    IF v_target_id = p_actor_user_id THEN
        p_msg := 'You cannot change your own role.';
        RETURN;
    END IF;

    SELECT ROLE_ID INTO v_support_role_id
      FROM SYSTEM_ROLE
     WHERE UPPER(ROLE_NAME) = 'BANK SUPPORT';

    SELECT ROLE_ID INTO v_user_role_id
      FROM SYSTEM_ROLE
     WHERE UPPER(ROLE_NAME) = 'USER';

    IF p_enable = 1 THEN
        IF v_target_role NOT IN ('USER', 'BANK SUPPORT') THEN
            p_msg := 'Only regular users can be made Bank Support.';
            RETURN;
        END IF;
        UPDATE USERDETAIL SET ROLE_ID = v_support_role_id WHERE USERDETAILID = v_target_id;
        p_msg := 'User ' || p_target_bank_id || ' is now Bank Support.';
    ELSE
        IF v_target_role <> 'BANK SUPPORT' THEN
            p_msg := 'User is not Bank Support.';
            RETURN;
        END IF;
        UPDATE USERDETAIL SET ROLE_ID = v_user_role_id WHERE USERDETAILID = v_target_id;
        p_msg := 'Bank Support role removed from ' || p_target_bank_id || '.';
    END IF;

    p_success := 1;
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        p_success := 0;
        p_msg     := SQLERRM;
END;
/

-- ===========================================================================
-- 7. DROP OBSOLETE ROLE-ASSIGNMENT PROCEDURES
-- ===========================================================================
BEGIN
    EXECUTE IMMEDIATE 'DROP PROCEDURE SP_GET_ASSIGNABLE_ROLES';
EXCEPTION WHEN OTHERS THEN NULL;
END;
/
BEGIN
    EXECUTE IMMEDIATE 'DROP PROCEDURE SP_GET_USERS_FOR_ROLE_ASSIGN';
EXCEPTION WHEN OTHERS THEN NULL;
END;
/
BEGIN
    EXECUTE IMMEDIATE 'DROP PROCEDURE SP_ASSIGN_USER_ROLE';
EXCEPTION WHEN OTHERS THEN NULL;
END;
/
BEGIN
    EXECUTE IMMEDIATE 'DROP PROCEDURE SP_GET_ROLES';
EXCEPTION WHEN OTHERS THEN NULL;
END;
/

-- ===========================================================================
--  VERIFY AFTERWARDS
--   SELECT object_name, object_type FROM user_objects WHERE status = 'INVALID';
--   Users must RE-LOGIN (or change password) to pick up the new menu assignments.
--   Superadmin: use Assign Menu to grant menus and toggle Bank Support users.
-- ===========================================================================