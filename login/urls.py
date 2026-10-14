from django.urls import path

from login import views

urlpatterns = [
    path('', views.login_view, name='login_page'),
    path('register/', views.register_user, name='register'),
    path('forgot-password/', views.forget_password, name='forgot_password'),
    path('force-change-password/', views.force_change_password, name='force_change_password'),
    path('admin/dashboard/', views.admin_dashboard, name='admin_dashboard'),
    path('admin/bank-support/<str:user_id>/<str:action>/', views.set_bank_support, name='set_bank_support'),
    path('dashboard/status/<str:user_id>/<str:status>/', views.set_account_status, name='set_account_status'),

    path('manager/dashboard/', views.manager_dashboard, name='manager_dashboard'),
    path('manager/approve/<int:reg_id>/', views.approve_user, name='approve_user'),
    path('manager/unlock/<str:user_id>/', views.unlock_user, name='unlock_user'),

    path('user-unlock/', views.user_unlock, name='user_unlock'),
    path('user-unlock/<str:mobileno>/', views.user_unlock, name='user_unlock_by_mobile'),

    path('ejanata-user-unlock/', views.ejanata_user_unlock, name='ejanata_user_unlock'),
    path('ejanata-user-unlock/<str:mobileno>/', views.ejanata_user_unlock, name='ejanata_user_unlock_by_mobile'),

    path('disable-ejanata-user/', views.disable_ejanata_user, name='disable_ejanata_user'),
    path('disable-ejanata-user/<str:mobileno>/', views.disable_ejanata_user, name='disable_ejanata_user_by_mobile'),

    path('acc-statement/', views.acc_statement, name='acc_statement'),

    path('disable-enable/', views.disable_enable, name='disable_enable'),
    path('disable-enable/<str:mobileno>/', views.disable_enable, name='disable_enable_by_mobile'),

    path('manage-user/', views.manageuser, name='manageuser'),

    path('assign-menu/', views.assign_menu, name='assign_menu'),
    path('assign-role/', views.assign_role_legacy, name='assign_role'),

    path('pending-registration/', views.pending_registration, name='pending_registration'),
    path('dashboard/', views.dashboard, name='dashboard'),
    path('logout/', views.logout_view, name='logout'),
    path('audit-trail/', views.audit_trail, name='audit_trail'),
    path('change-password/', views.change_password, name='change_password'),
    path('create-manager/', views.create_manager, name='create_manager'),
]