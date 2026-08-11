"""Architecture diagram for gcp-zero-trust-access.

Renders docs/architecture.png using the official GCP icon set.

    pip install diagrams   # requires graphviz: brew install graphviz
    python diagram.py

Drawn around the boundary, not around the request flow. A left to right request
diagram would show a proxy in front of a container, which is the least
interesting thing here and looks identical to every reverse proxy ever drawn.

What the picture has to carry is that the same identity gets two different
answers depending on which side of the perimeter it is standing on. So the
analyst service account appears twice, once inside and once outside, and the two
arrows leaving it are drawn in different colors and land in different places.
Everything else is arranged to keep those two arrows readable.
"""

from diagrams import Cluster, Diagram, Edge
from diagrams.gcp.analytics import BigQuery
from diagrams.gcp.compute import ComputeEngine, Run
from diagrams.gcp.network import VirtualPrivateCloud
from diagrams.gcp.security import IAP, ResourceManager
from diagrams.gcp.storage import GCS
from diagrams.onprem.client import User

GRAPH_ATTR = {
    "fontsize": "16",
    "labelloc": "t",
    "pad": "0.6",
    "splines": "spline",
    "nodesep": "0.8",
    "ranksep": "1.2",
    "bgcolor": "transparent",
}

ALLOW = {"color": "darkgreen", "style": "bold"}
DENY = {"color": "firebrick", "style": "bold"}
FLOW = {"color": "dimgray"}
EVAL = {"color": "darkblue", "style": "dashed"}

with Diagram(
    "GCP Zero Trust Access",
    filename="docs/architecture",
    show=False,
    direction="LR",
    graph_attr=GRAPH_ATTR,
):
    # Declaration order is doing layout work. Callers first, then the policy
    # objects they are evaluated against, then the things being protected, so
    # graphviz ranks them left to right without the edges having to cross back.
    with Cluster("outside the perimeter"):
        admin = User("administrator\nidentity + network")
        attacker = User("analyst SA\nimpersonated")

    with Cluster("Access Context Manager (org scope)"):
        trusted = ResourceManager("trusted level\nidentity AND ip")
        management = ResourceManager("management level\nidentity only\nbreak glass")

    with Cluster("identity-aware front door"):
        iap = IAP("Identity-Aware Proxy")
        app = Run("Cloud Run\niap_enabled")

    with Cluster("service perimeter: workload project"):
        with Cluster("VPC, no external IP, no NAT"):
            inside = ComputeEngine("instance\nruns as analyst SA")
            vpc = VirtualPrivateCloud("Private Google Access\nrestricted VIP")

        bucket = GCS("Cloud Storage\nrestricted")
        dataset = BigQuery("BigQuery\nrestricted")

    # The front door. IAP evaluates the trusted level per request, so losing the
    # context revokes access without the IAM role changing.
    trusted >> Edge(label="IAM condition", **EVAL) >> iap
    admin >> Edge(label="https", **FLOW) >> iap
    iap >> Edge(label="admitted", **ALLOW) >> app

    # The tunnel. No inbound path to the instance other than this one.
    admin >> Edge(label="IAP TCP tunnel\nno public IP", **ALLOW) >> inside
    inside >> Edge(**FLOW) >> vpc

    # The comparison the whole build exists to make. Same identity, same role,
    # same object, opposite answers.
    vpc >> Edge(label="reads", **ALLOW) >> bucket
    attacker >> Edge(label="same role, denied", **DENY) >> bucket
    attacker >> Edge(label="denied", **DENY) >> dataset

    # The escape hatch, drawn because leaving it implicit would misrepresent the
    # perimeter as stronger than it is.
    management >> Edge(label="perimeter ingress", **EVAL) >> bucket
