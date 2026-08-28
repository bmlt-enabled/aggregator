import os
import json
import boto3

sns_topic = os.environ.get('SNS_TOPIC')
sns = boto3.client('sns')


def lambda_handler(event, context):
    print(json.dumps(event))
    detail = event.get("detail", {})

    task_arn = detail.get("taskArn", "unknown")
    task_id = task_arn.split("/")[-1]
    stop_code = detail.get("stopCode", "unknown")
    stopped_reason = detail.get("stoppedReason", "unknown")
    group = detail.get("group", "unknown")
    stopped_at = detail.get("stoppedAt", "unknown")

    container_lines = []
    for container in detail.get("containers", []):
        name = container.get("name", "?")
        exit_code = container.get("exitCode", "n/a")
        reason = container.get("reason", "")
        line = f"  - {name}: exitCode={exit_code}"
        if reason:
            line += f" reason={reason}"
        container_lines.append(line)
    containers_text = "\n".join(container_lines) or "  (none reported)"

    message = (
        "Aggregator task stopped due to failure.\n\n"
        f"Task:           {task_id}\n"
        f"Group:          {group}\n"
        f"Stop code:      {stop_code}\n"
        f"Stopped reason: {stopped_reason}\n"
        f"Stopped at:     {stopped_at}\n"
        f"Containers:\n{containers_text}\n"
    )

    sns.publish(
        TargetArn=sns_topic,
        Message=json.dumps({'default': message}),
        Subject=f'Aggregator Task Stopped: {stop_code}'[:100],
        MessageStructure='json'
    )
