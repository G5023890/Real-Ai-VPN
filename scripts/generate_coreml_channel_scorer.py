#!/usr/bin/env python3
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".build", "python-coremltools"))

import coremltools as ct
import numpy as np
from coremltools.models import MLModel, datatypes, neural_network


FEATURE_COUNT = 12
OUTPUT_PATH = os.path.join(
    os.path.dirname(__file__),
    "..",
    "Resources",
    "CoreML",
    "RealAiVPNChannelScorer.mlmodel",
)


def main() -> None:
    builder = neural_network.NeuralNetworkBuilder(
        input_features=[("features", datatypes.Array(FEATURE_COUNT))],
        output_features=[("channelScore", datatypes.Array(1))],
        mode="regressor",
        use_float_arraytype=False,
    )

    # The first bundled model is a transparent baseline: it lets CoreML own the
    # prediction path while keeping behavior close to the existing heuristic.
    weights = np.array(
        [[
            1.65,  # heuristicScore
            1.15,  # inverse degradation risk
            0.85,  # estimated success rate
            0.35,  # DNS availability
            0.25,  # DoH availability
            0.35,  # TCP endpoint reachability
            0.45,  # VPN endpoint reachability
            0.45,  # exit IP consistency
            0.35,  # low recent latency
            0.25,  # low recent handshake time
            0.55,  # low packet loss
            0.25,  # low recent failure pressure
        ]],
        dtype=np.float32,
    )
    bias = np.array([-3.45], dtype=np.float32)

    builder.add_inner_product(
        name="weighted_channel_quality",
        W=weights,
        b=bias,
        input_channels=FEATURE_COUNT,
        output_channels=1,
        has_bias=True,
        input_name="features",
        output_name="channel_logit",
    )
    builder.add_activation(
        name="bounded_channel_score",
        non_linearity="SIGMOID",
        input_name="channel_logit",
        output_name="channelScore",
    )

    spec = builder.spec
    spec.specificationVersion = 5
    spec.description.predictedFeatureName = "channelScore"
    spec.description.metadata.author = "Real Ai Router"
    spec.description.metadata.shortDescription = "CoreML baseline scorer for VPN channel ranking."
    spec.description.metadata.versionString = "0.93.1"

    os.makedirs(os.path.dirname(OUTPUT_PATH), exist_ok=True)
    MLModel(spec).save(OUTPUT_PATH)
    print(OUTPUT_PATH)


if __name__ == "__main__":
    main()
