"""Read-only release acceptance, including configuration health missed by probes."""

from pathlib import Path

from sqlalchemy import func, select, text
from sqlalchemy.engine import make_url

from forest_api import activity, collection, services, shop, visitors
from forest_api.collection_models import ExchangeOffer
from forest_api.database import Database
from forest_api.item_models import ShopWeek
from forest_api.models import SkillPolicy
from forest_api.routes import SCHEMA_REVISION
from forest_api.skill_rules import CAPS_VERSION, SkillCaps


def inspect(settings, *, allow_maintenance=False):
    if settings.environment != "production" or settings.auth_mode != "jwks":
        raise ValueError("Preflight requires production and JWKS authentication")
    url = make_url(settings.database_url.get_secret_value())
    if url.query.get("sslmode") != "verify-full":
        raise ValueError("Production database TLS must use verify-full")
    if not Path(url.query.get("sslrootcert", "")).is_file():
        raise ValueError("Database CA certificate is missing")
    database = Database(settings)
    try:
        with database.sessions() as session, session.begin():
            return database_report(session, settings, allow_maintenance=allow_maintenance)
    finally:
        database.engine.dispose()


def database_report(session, settings, *, allow_maintenance=False):
    """Run content/permission acceptance inside the caller's read-only transaction."""
    session.execute(text("SET TRANSACTION READ ONLY"))
    session.execute(text("SET LOCAL statement_timeout = '15s'"))
    session.execute(text("SET LOCAL TIME ZONE 'UTC'"))
    if session.scalars(text("SELECT version_num FROM alembic_version")).all() != [SCHEMA_REVISION]:
        raise ValueError("Schema does not match this release")
    role = session.execute(
        text(
            "SELECT rolname,rolsuper,rolcreatedb,rolcreaterole,rolbypassrls "
            "FROM pg_roles WHERE rolname=current_user"
        )
    ).one()
    if role.rolname != "forest_runtime" or any(role[1:]):
        raise ValueError("Preflight must use the restricted forest_runtime login")
    enabled = session.execute(
        text("SELECT maintenance FROM runtime_control WHERE id=1")
    ).scalar_one()
    if enabled and not allow_maintenance:
        raise ValueError("Maintenance is still enabled")
    now = session.scalar(select(func.clock_timestamp()))
    catalogue = services.get_catalogue_state(session, settings)
    economy = activity.configuration(session, settings, now)
    visitor_rule, definition = visitors.rule_at(session, settings, now)
    policy = session.get(SkillPolicy, definition.skill_policy_version or CAPS_VERSION)
    if policy is None:
        raise ValueError("Published skill policy is missing")
    SkillCaps.model_validate(policy.rules)
    offers = session.scalars(select(ExchangeOffer).where(ExchangeOffer.active)).all()
    if not offers:
        raise ValueError("No published pack offers")
    for offer in offers:
        collection.pack_contract(session, settings, offer.pack_id, offer.pack_version)
    release = shop.active_release(session, now)
    if release is None or release.policy.get("algorithm") != 1:
        raise ValueError("Published shop policy is missing or unsupported")
    if session.get(ShopWeek, shop.week_of(now.date())) is None:
        raise ValueError("Prepare the current shop rotation before reopening")
    # Check SELECT access and RLS on every mapped game table without
    # exporting a player's records. Writes are tested in disposable CI.
    from forest_api.models import Base

    quote = session.bind.dialect.identifier_preparer.quote_identifier
    for name in sorted(Base.metadata.tables):
        session.execute(text(f"SELECT 1 FROM public.{quote(name)} LIMIT 0"))
        if not session.scalar(
            text("SELECT relrowsecurity FROM pg_class WHERE oid=to_regclass(:name)"),
            {"name": f"public.{name}"},
        ):
            raise ValueError("A game table is missing RLS")
    return {
        "status": "ready",
        "schema": SCHEMA_REVISION,
        "catalogue": catalogue.version,
        "economy": economy.version,
        "visitors": visitor_rule.version,
        "shop": release.version,
        "maintenance": enabled,
        "tables": len(Base.metadata.tables),
    }
