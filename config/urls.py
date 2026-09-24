from django.contrib import admin
from django.urls import path, include
from django.conf import settings
from django.conf.urls.static import static
from login import views

urlpatterns = [
    path('admin/', admin.site.urls),
    path('', views.login_view, name='login_page'),
    path('register/', views.register_user, name='register'),
    path('forgot-password/', views.forget_password, name='forgot_password'),
    path('force-change-password/', views.force_change_password, name='force_change_password'),
    path('manager/dashboard/', views.manager_dashboard, name='manager_dashboard'),
    path('manager/approve/<int:reg_id>/', views.approve_user, name='approve_user'),
    path('manager/unlock/<str:user_id>/', views.unlock_user, name='unlock_user'),
    path('user-unlock/', views.user_unlock, name='user_unlock'),
    path('user-unlock/<str:mobileno>/', views.user_unlock, name='user_unlock_by_mobile'),
    path('assign-menu/', views.assign_menu, name='assign_menu'),
    path('assign-role/', views.assign_role_legacy, name='assign_role'),

    path('pending-registration/', views.pending_registration, name='pending_registration'),
    path('dashboard/', views.dashboard, name='dashboard'),
    path('logout/', views.logout_view, name='logout'),
    path('audit-trail/', views.audit_trail, name='audit_trail'),
    path('change-password/', views.change_password, name='change_password'),
    path('create-manager/', views.create_manager, name='create_manager'),

    path('', include('ticket.urls')),
]

if settings.DEBUG:
    urlpatterns += static(settings.MEDIA_URL, document_root=settings.MEDIA_ROOT)