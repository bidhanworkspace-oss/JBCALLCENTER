
WHENEVER SQLERROR CONTINUE
/

DECLARE
    v_id NUMBER;
BEGIN
    BEGIN
        SELECT MENU_ID INTO v_id
          FROM SYSTEM_MENU
         WHERE URL_NAME = 'disable_ejanata_user';
    EXCEPTION WHEN NO_DATA_FOUND THEN
        INSERT INTO SYSTEM_MENU (MENU_TITLE, URL_NAME, PARENT_ID, ICON_CLASS, DISPLAY_ORDER)
        VALUES ('Disable eJanata User', 'disable_ejanata_user', NULL, 'bi-slash-circle', 12);
    END;

    BEGIN
        SELECT MENU_ID INTO v_id
          FROM SYSTEM_MENU
         WHERE URL_NAME = 'acc_statement';
    EXCEPTION WHEN NO_DATA_FOUND THEN
        INSERT INTO SYSTEM_MENU (MENU_TITLE, URL_NAME, PARENT_ID, ICON_CLASS, DISPLAY_ORDER)
        VALUES ('Acc Statement', 'acc_statement', NULL, 'bi-file-earmark-text', 13);
    END;

    COMMIT;
END;
/

DECLARE
    v_menu_id NUMBER;
BEGIN
    FOR v_url IN (SELECT 'disable_ejanata_user' AS u FROM DUAL
                  UNION ALL SELECT 'acc_statement' FROM DUAL) LOOP
        SELECT MENU_ID INTO v_menu_id
          FROM SYSTEM_MENU
         WHERE URL_NAME = v_url.u;

        FOR r IN (SELECT ROLE_ID
                    FROM SYSTEM_ROLE
                   WHERE UPPER(TRIM(ROLE_NAME)) = 'SUPERADMIN') LOOP
            INSERT INTO ROLE_MENU_PERMISSION (ROLE_ID, MENU_ID)
            SELECT r.ROLE_ID, v_menu_id FROM DUAL
             WHERE NOT EXISTS (SELECT 1 FROM ROLE_MENU_PERMISSION x
                                WHERE x.ROLE_ID = r.ROLE_ID
                                  AND x.MENU_ID = v_menu_id);
        END LOOP;
    END LOOP;

    COMMIT;
END;
/

DECLARE
    v_menu_id NUMBER;
BEGIN
    FOR v_url IN (SELECT 'disable_ejanata_user' AS u FROM DUAL
                  UNION ALL SELECT 'acc_statement' FROM DUAL) LOOP
        SELECT MENU_ID INTO v_menu_id
          FROM SYSTEM_MENU
         WHERE URL_NAME = v_url.u;

        INSERT INTO USER_MENU_ASSIGNMENT (USERDETAILID, MENU_ID, ASSIGNED_BY_USER_ID, ASSIGNED_AT)
        SELECT u.USERDETAILID, v_menu_id, NULL, CURRENT_TIMESTAMP
          FROM USERDETAIL u
          JOIN SYSTEM_ROLE r ON r.ROLE_ID = u.ROLE_ID
         WHERE UPPER(TRIM(r.ROLE_NAME)) = 'SUPERADMIN'
           AND NOT EXISTS (SELECT 1 FROM USER_MENU_ASSIGNMENT a
                            WHERE a.USERDETAILID = u.USERDETAILID
                              AND a.MENU_ID = v_menu_id);
    END LOOP;

    COMMIT;
END;
/

COMMIT;

