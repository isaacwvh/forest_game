import argparse
import json
from datetime import datetime
from pathlib import Path

from forest_api.auth import issue_development_token
from forest_api.config import Settings
from forest_api.database import Database
from forest_api.seed import seed_development_catalogue


def main() -> None:
    parser = argparse.ArgumentParser(description="Movement Forest development tools")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("seed-dev", help="Seed explicitly unapproved local/test catalogue")
    token = commands.add_parser("dev-token", help="Issue a local/test-only 30-minute token")
    token.add_argument("subject")
    publish = commands.add_parser(
        "publish-visitor-rules", help="Publish immutable future visitor rules"
    )
    publish.add_argument("file", type=Path)
    publish.add_argument("--version", required=True)
    publish.add_argument("--effective-at", required=True)
    publish.add_argument("--fixture", action="store_true")
    args = parser.parse_args()
    settings = Settings()
    if args.command == "dev-token":
        print(issue_development_token(settings, args.subject))
        return
    database = Database(settings)
    try:
        with database.sessions() as session:
            if args.command == "publish-visitor-rules":
                from forest_api.visitor_schemas import VisitorRuleDefinition
                from forest_api.visitors import publish_rules

                definition = VisitorRuleDefinition.model_validate(json.loads(args.file.read_text()))
                publish_rules(
                    session,
                    settings,
                    args.version,
                    definition,
                    datetime.fromisoformat(args.effective_at),
                    is_fixture=args.fixture,
                )
                print("Future visitor rule version published; previous earnings are unchanged.")
            else:
                seed_development_catalogue(session, settings)
                print("Development catalogue ready; all balance values are fixtures.")
    finally:
        database.engine.dispose()


if __name__ == "__main__":
    main()
