import { route as health } from './routes/health.ts';
import { route as stockList } from './routes/list-stock.ts';
import { route as stockAdd } from './routes/add-stock.ts';
import { route as stockGet } from './routes/get-stock.ts';
import { route as reservationCreate } from './routes/reserve.ts';
import { route as reservationCancel } from './routes/cancel.ts';
import { route as reservationFulfill } from './routes/fulfill.ts';
import { route as report } from './routes/report.ts';
export const routes = Object.freeze([health, stockList, stockAdd, stockGet, reservationCreate, reservationCancel, reservationFulfill, report]);
