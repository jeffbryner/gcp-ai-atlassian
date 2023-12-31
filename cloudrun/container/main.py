import os
import logging
from atlassian import Jira

logging.basicConfig(level=logging.DEBUG)
logger = logging.getLogger()

from flask import Flask, request

flask_app = Flask(__name__)


@flask_app.route("/", methods=["GET", "POST"])
def hello_world():
    name = os.environ.get("NAME", "World")
    return "HELLO {}!".format(name)


@flask_app.route("/jira-webhook", methods=["POST"])
def jira_events():
    logger.debug("jira webhook event received!")
    headers = dict(request.headers)
    headers.pop("Authorization", None)  # do not log authorization header if exists
    logger.debug(headers)
    body = dict(request.json)
    logger.debug(body)

    return ("OK", 200)
