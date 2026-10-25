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
    commands.add_parser("seed-skills-dev", help="Publish Sleeping Dew and new development packs")
    commands.add_parser(
        "publish-launch-balance", help="Publish the approved two-species activity economy"
    )
    activity_grant = commands.add_parser(
        "grant-activity-test-plants", help="Grant two new-profile test sprouts"
    )
    activity_grant.add_argument("username")
    activity_grant.add_argument("--dry-run", action="store_true")
    grant = commands.add_parser(
        "grant-adult-moonwillow", help="Grant one mature test copy into storage"
    )
    grant.add_argument("username")
    grant.add_argument("--dry-run", action="store_true")
    collection_publish = commands.add_parser(
        "publish-pack", help="Validate and publish an immutable pack/offer JSON file"
    )
    collection_publish.add_argument("file", type=Path)
    retire = commands.add_parser("retire-offer", help="Stop sales; preserve already acquired packs")
    retire.add_argument("offer_id")
    retire.add_argument("--version", required=True, type=int)
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
            if args.command == "publish-launch-balance":
                from forest_api.launch_balance import publish

                print(json.dumps(publish(session, settings)))
            elif args.command == "grant-activity-test-plants":
                from forest_api.launch_balance import grant_test_plants

                print(
                    json.dumps(
                        grant_test_plants(session, settings, args.username, dry_run=args.dry_run)
                    )
                )
            elif args.command == "seed-skills-dev":
                from forest_api.skill_seed import seed_skills

                seed_skills(session, settings)
                print("Sleeping Dew published; legacy plants and packs retain their profiles.")
            elif args.command == "grant-adult-moonwillow":
                from forest_api.skill_seed import grant_adult_moonwillow

                print(
                    json.dumps(
                        grant_adult_moonwillow(
                            session, settings, args.username, dry_run=args.dry_run
                        )
                    )
                )
            elif args.command == "retire-offer":
                from forest_api.collection import retire_offer

                retire_offer(session, settings, args.offer_id, args.version)
                print("Offer retired; existing owned packs remain openable.")
            elif args.command == "publish-pack":
                from forest_api.collection import publish as publish_pack
                from forest_api.collection_schemas import PublishPack

                publish_pack(
                    session,
                    settings,
                    PublishPack.model_validate_json(args.file.read_text(encoding="utf-8")),
                )
                print(
                    "Pack/offer version published; existing owned packs retain their definitions."
                )
            elif args.command == "publish-visitor-rules":
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
                from forest_api.collection_seed import seed_collection

                seed_collection(session, settings)
                print("Development catalogue ready; all balance values are fixtures.")
    finally:
        database.engine.dispose()


if __name__ == "__main__":
    main()
