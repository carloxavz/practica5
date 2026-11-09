import base64
import binascii
import logging
import os
import random
import time
from collections import Counter
from datetime import datetime, timezone
from functools import cache

from flask import Flask, request
from google.cloud import firestore

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("cocina")

BASE_DATOS = os.environ.get("BASE_DATOS", "(default)")
TIEMPO_PREPARACION = float(os.environ.get("TIEMPO_PREPARACION", "6"))
PROBABILIDAD_FALLO = float(os.environ.get("PROBABILIDAD_FALLO", "0"))
PLATO_MISTERIOSO = "plato-misterioso"

app = Flask(__name__)


@cache
def db():
    return firestore.Client(database=BASE_DATOS)


def ahora():
    return datetime.now(timezone.utc)


TERMINADOS = ("listo", "rechazado")


@firestore.transactional
def terminar(transaccion, pedido_ref, cantidades):
    """Revisa el estado, revisa existencias y descuenta de forma atómica.

    Devuelve "repetido" si el pedido ya estaba terminado, "listo" si se
    descontó, o la lista de productos que faltan si se rechazó.
    """
    # En una transacción todas las lecturas van antes que las escrituras.
    pedido = pedido_ref.get(transaction=transaccion)
    if pedido.get("estado") in TERMINADOS:
        return "repetido"

    inventario = db().collection("inventario")
    existencias = {
        producto: (inventario.document(producto).get(transaction=transaccion).get("existencias") or 0)
        for producto in cantidades
    }
    faltan = [p for p, cantidad in cantidades.items() if existencias[p] < cantidad]
    if faltan:
        transaccion.update(pedido_ref, {
            "estado": "rechazado",
            "motivo": "Se acabó: " + ", ".join(faltan),
            "actualizado": ahora(),
        })
        return faltan

    for producto, cantidad in cantidades.items():
        transaccion.update(inventario.document(producto), {"existencias": existencias[producto] - cantidad})
    transaccion.update(pedido_ref, {"estado": "listo", "actualizado": ahora()})
    return "listo"


@app.post("/")
def recibir():
    # Pub/Sub entrega un sobre JSON: {"message": {"data": <base64>, ...},
    # "subscription": ..., "deliveryAttempt": n}. El último campo solo viene
    # cuando la suscripción tiene política de mensajes muertos.
    sobre = request.get_json(silent=True)
    try:
        pedido_id = base64.b64decode(sobre["message"]["data"], validate=True).decode()
    except (TypeError, KeyError, binascii.Error, UnicodeDecodeError):
        log.error("Llegó un sobre que no es de Pub/Sub o no trae data: %r", sobre)
        return "sobre inválido", 400

    intento = sobre.get("deliveryAttempt")
    log.info("Pedido %s, intento de entrega %s", pedido_id, intento or "desconocido")

    pedido_ref = db().collection("pedidos").document(pedido_id)
    pedido = pedido_ref.get()
    if not pedido.exists:
        # Se confirma igual: reintentar un pedido que no existe no lo va a crear.
        log.warning("El pedido %s no existe; se descarta el mensaje", pedido_id)
        return "", 204

    # Idempotencia, primer filtro (barato): si una entrega anterior ya lo terminó,
    # se confirma sin volver a prepararlo ni descontar nada.
    if pedido.get("estado") in TERMINADOS:
        log.info("Pedido %s ya estaba %s; entrega repetida, no se descuenta otra vez",
                 pedido_id, pedido.get("estado"))
        return "", 204

    if pedido.get("estado") == "recibido":
        pedido_ref.update({"estado": "preparando", "actualizado": ahora()})

    cantidades = Counter()
    for item in pedido.get("items"):
        cantidades[item["producto"]] += item["cantidad"]

    if PLATO_MISTERIOSO in cantidades:
        raise RuntimeError(f"La cocina no tiene receta para el plato misterioso (pedido {pedido_id})")

    time.sleep(TIEMPO_PREPARACION)

    # Idempotencia, filtro definitivo: revisar el estado del pedido, revisar las
    # existencias y descontar van en UNA transacción. Si dos entregas del mismo
    # pedido llegan a la vez a dos instancias, Firestore serializa las dos
    # transacciones: la segunda se reintenta, ve el pedido ya terminado y no
    # descuenta. Lo mismo evita el inventario negativo de la fase 4.
    resultado = terminar(db().transaction(), pedido_ref, cantidades)
    if resultado == "repetido":
        log.info("Pedido %s lo terminó otra entrega mientras se preparaba; no se descuenta otra vez", pedido_id)
    elif resultado == "listo":
        log.info("Pedido %s listo", pedido_id)
    else:
        log.info("Pedido %s rechazado, no alcanza: %s", pedido_id, resultado)

    # Simula que la cocina se cae justo después de terminar y antes de confirmar.
    # Pub/Sub no recibe el 2xx y vuelve a entregar el mismo pedido.
    if random.random() < PROBABILIDAD_FALLO:
        log.warning("Falla simulada en el pedido %s: el trabajo quedó hecho pero no se confirma", pedido_id)
        return "falla simulada", 500

    return "", 204
