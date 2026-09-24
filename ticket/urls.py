from django.urls import path

from ticket import views

urlpatterns = [
    path('tickets/raise/', views.raise_ticket, name='raise_ticket'),
    path('tickets/', views.tickets_list, name='tickets'),
    path('tickets/<int:ticket_id>/', views.ticket_detail, name='ticket_detail'),
]