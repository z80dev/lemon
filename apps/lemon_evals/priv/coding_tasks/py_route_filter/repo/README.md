# Shipment route filters

Dispatch rules compare shipment attributes with string literals. `routing.parse` compiles configuration into tuple trees and `routing.matches` evaluates them for each shipment. The historical parser handles a single comparison or flat conjunction; the change request defines the full grammar and diagnostic offsets. `routing.rules.select` returns names of matching configured routes.

Run visible checks with `python3 -m unittest discover -s tests -v`.
