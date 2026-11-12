import json
def port(environment):
 with open('config.json') as f: config=json.load(f)
 return config['base_port']+config['environments'][environment]['offset']
