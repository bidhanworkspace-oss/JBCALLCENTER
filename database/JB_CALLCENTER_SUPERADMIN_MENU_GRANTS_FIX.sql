WHENEVER SQLERROR CONTINUE
/

DECLARE
    v_mid NUMBER;
BEGIN
    FOR v_url IN (SELECT 'assign_menu' AS u FROM DUAL
                  UNION ALL SELECT 'acc_statement' FROM DUAL) LOOP
        BEGIN
            SELECT MENU_ID INTO v_mid FROM SYSTEM_MENU WHERE URL_NAME = v_url.u;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                INSERT INTO SYSTEM_MENU (MENU_TITLE, URL_NAME, PARENT_ID, ICON_CLASS, DISPLAY_ORDER)
                VALUES (
                    CASE WHEN v_url.u = 'assign_menu' THEN 'Assign Menu' ELSE 'Acc Statement' END,
                    v_url.u, NULL,
                    CASE WHEN v_url.u = 'assign_menu' THEN 'bi-person-badge' ELSE 'bi-file-earmark-text' END,
                    CASE WHEN v_url.u = 'assign_menu' THEN 4 ELSE 13 END
                )
                RETURNING MENU_ID INTO v_mid;
        END;

        INSERT INTO USER_MENU_ASSIGNMENT (USERDETAILID, MENU_ID, ASSIGNED_BY_USER_ID, ASSIGNED_AT)
        SELECT u.USERDETAILID, v_mid, NULL, CURRENT_TIMESTAMP
          FROM USERDETAIL u
          JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
         WHERE UPPER(TRIM(r.ROLE_NAME)) = 'SUPERADMIN'
           AND NOT EXISTS (SELECT 1 FROM USER_MENU_ASSIGNMENT a
                            WHERE a.USERDETAILID = u.USERDETAILID AND a.MENU_ID = v_mid);

        IF v_url.u = 'assign_menu' THEN
            INSERT INTO USER_MENU_ASSIGNMENT (USERDETAILID, MENU_ID, ASSIGNED_BY_USER_ID, ASSIGNED_AT)
            SELECT u.USERDETAILID, v_mid, NULL, CURRENT_TIMESTAMP
              FROM USERDETAIL u
              JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
             WHERE UPPER(TRIM(r.ROLE_NAME)) = 'MANAGER'
               AND NOT EXISTS (SELECT 1 FROM USER_MENU_ASSIGNMENT a
                                WHERE a.USERDETAILID = u.USERDETAILID AND a.MENU_ID = v_mid);
        END IF;
    END LOOP;
    COMMIT;
END;
/

COMMIT;