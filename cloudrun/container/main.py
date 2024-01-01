import os
import logging
import yaml, json
from atlassian import Confluence
from jira import JIRA
from flask import Flask, request
import google.auth
from utils import get_secret, text_generation_model_with_backoff
import html2text

logging.basicConfig(level=logging.DEBUG)
logger = logging.getLogger()

credentials, PROJECT_ID = google.auth.default()
flask_app = Flask(__name__)

# get our config
config = yaml.safe_load(open("config.yaml"))
logger.debug(f"our config: {config}")


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
    logger.info(body)
    if "webhookEvent" in body and body["webhookEvent"] == "jira:issue_created":
        # call AI to attach some labels to this issue
        jira_api_token = get_secret(PROJECT_ID, "jira_api_token")
        jira = JIRA(
            server=config["jira_url"], basic_auth=(config["jira_user"], jira_api_token)
        )
        # reference the issue in the webhook
        issue = jira.issue(body["issue"]["key"])

        # get the context for our AI prompt from a confluence page
        confluence = Confluence(
            url=config["jira_url"],
            username=config["jira_user"],
            password=jira_api_token,
            cloud=True,
        )
        # convert the html to plain text/markdown
        h = html2text.HTML2Text()
        h.ignore_links = True
        ai_context_page = confluence.get_page_by_title(
            title=config["context_page"],
            space=config["context_space"],
            expand="body.view",
        )
        ai_context = h.handle(ai_context_page["body"]["view"]["value"])
        prompt = f"""
            {ai_context}
            Issue: {issue.fields.summary} {issue.fields.description}
        """
        ai_output = text_generation_model_with_backoff(
            prompt=prompt,
            temperature=0,
        )
        logger.debug(f"AI returned: {ai_output}")
        try:
            ai_labels = json.loads(ai_output)
            for label in ai_labels:
                issue.fields.labels.append(label)
            issue.update(fields={"labels": issue.fields.labels})
        except Exception as e:
            logger.error(f"Error reading AI output and attaching labels {e}")

    return ("OK", 200)
