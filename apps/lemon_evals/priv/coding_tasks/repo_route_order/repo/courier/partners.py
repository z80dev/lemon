from .model import Rule
def rules():
    return [Rule('alpha','CA',('standard','priority'),30,True,500,50,20),
            Rule('zeta','CA',('standard','priority'),30,True,600,50,20)]
