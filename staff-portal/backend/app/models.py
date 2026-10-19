from pydantic import BaseModel, Field


class CreateDomain(BaseModel):
    fqdn: str = Field(..., examples=["orange.rmorse.com"])
    user_count: int = Field(20, ge=1, le=500)
    dry_run: bool = False
