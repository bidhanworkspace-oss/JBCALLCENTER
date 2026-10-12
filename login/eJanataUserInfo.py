
import django
from django.db import models

class eJanataUserInfo(models.Model):
    Appuserinfoid           =  models.CharField(max_length=100)
    Appusername             =  models.CharField(max_length=100)
    Appuserstatusid         =  models.CharField(max_length=100)
    Accounttitle            =  models.CharField(max_length=100)
    Name                    =  models.CharField(max_length=100)
    Dob                     =  models.CharField(max_length=100)
    Mobileno                =  models.CharField(max_length=100)
    Emailaddrs              =  models.CharField(max_length=100)
    Nid                     =  models.CharField(max_length=100)

    Cbsaccountno            =  models.CharField(max_length=100)
    Cbsaccounttitle         =  models.CharField(max_length=100)
    Cbscustomerid           =  models.CharField(max_length=100)
    Cbsdateofbirth          =  models.CharField(max_length=100)
    Cbsemailaddrs           =  models.CharField(max_length=100)
    Cbsmobileno             =  models.CharField(max_length=100)
    Cbsnationalididdoc      =  models.CharField(max_length=100)

    Branchcode              =  models.CharField(max_length=100)
    Branchname              =  models.CharField(max_length=100)

    Isaccount               =  models.CharField(max_length=100)
    Isaccountmarker         =  models.CharField(max_length=100)
    Isconfirmationpending   =  models.CharField(max_length=100)
    Isdeviceactive          =  models.CharField(max_length=100)
    Isemailverified         =  models.CharField(max_length=100)
    Isuserverified          =  models.CharField(max_length=100)
    Istemppassword          =  models.CharField(max_length=100)
    Istemppasswordused      =  models.CharField(max_length=100)

    Confirmationlogid       =  models.CharField(max_length=100)
    Confirmationtypeid      =  models.CharField(max_length=100)
    Confirmationremarks     =  models.CharField(max_length=100)
    Pendingconfirmationtypeid = models.CharField(max_length=100)
    Confirmationdate        =  models.CharField(max_length=100)
    Confirmationbranchcode  =  models.CharField(max_length=100)
    Confirmationbranchname  =  models.CharField(max_length=100)
    Verifiedby              =  models.CharField(max_length=100)
    Verifieddate            =  models.CharField(max_length=100)
    Verifiedtype            =  models.CharField(max_length=100)
    Emailverifieddate       =  models.CharField(max_length=100)
    Creationdate            =  models.CharField(max_length=100)
    Devicename              =  models.CharField(max_length=100)
