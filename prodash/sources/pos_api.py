"""ProDairy's shop system (POS) API. Waiting for ProDairy to name the system.

When its documentation and test credentials arrive:
  1. Replace the example paths in header_map and line_map with the real ones
     (contract column -> dotted path in their receipt JSON).
  2. Implement fetch(): call the "receipts changed since" endpoint for one shop,
     page by page, and yield Page(receipts, cursor) with each page's newest change marker.
  3. Register the shops in ops.source_sync and run prodash.sync (docs/etl_worker.md).
"""

from prodash.sources.base import Source


class PosApi(Source):
    name = "pos_api"
    lines_key = "lines"
    # Example paths only; the real ones come from the API documentation.
    header_map = {
        "receipt_no": "number",
        "receipt_datetime": "created_at",
        "trader_code": "customer.code",
        "customer_name": "customer.name",
        "customer_cell": "customer.phone",
        "currency": "currency",
        "payment_method": "payment.method",
    }
    line_map = {
        "product": "item.name",
        "product_code": "item.sku",      # kept in extra; mapped through gold.ref_product_code
        "quantity": "quantity",
        "unit": "unit",
        "unit_price": "unit_price",
        "line_total": "total",
    }
