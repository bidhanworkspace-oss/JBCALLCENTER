from django.db import models


class ApiResponse(models.Model):
    data = []
    Message = models.CharField(max_length=500)
    ResponseCode = models.IntegerField()
    Status = models.CharField(max_length=250)

    raw = {}
