#!/usr/bin/env python3

import requests

URL = "https://allocations.my-eurohpc.eu/api/marketplace-public-offerings/"
PAGE_SIZE = 100


def get_all_offerings():
    """Fetch all offerings, handling both paginated and non-paginated responses."""

    offerings = []
    page = 1

    while True:
        response = requests.get(
            URL,
            params={
                "page": page,
                "page_size": PAGE_SIZE,
            },
            timeout=30,
        )
        response.raise_for_status()

        data = response.json()

        # API returns a plain list
        if isinstance(data, list):
            offerings.extend(data)
            break

        # Django REST Framework-style response
        if isinstance(data, dict):
            results = data.get("results", [])

            if not results:
                break

            offerings.extend(results)

            # Prefer following "next" if supplied by the API
            if not data.get("next"):
                break

            page += 1
            continue

        raise RuntimeError(
            f"Unexpected API response type: {type(data).__name__}"
        )

    return offerings


def print_architectures(offering):
    name = offering.get("name", "<unnamed offering>")
    uuid = offering.get("uuid", "<no uuid>")

    print()
    print("=" * 80)
    print(f"Offering: {name}")
    print(f"UUID:     {uuid}")
    print("=" * 80)

    # ------------------------------------------------------------------
    # Partitions
    # ------------------------------------------------------------------

    partitions = offering.get("partitions")

    if not partitions:
        print("WARNING: partitions is empty!")
    else:
        print("\nPartitions:")

        for partition in partitions:
            partition_name = partition.get(
                "partition_name",
                "<unnamed partition>",
            )

            cpu_arch = partition.get("cpu_arch")
            gpu_arch = partition.get("gpu_arch")

            print(f"\n  Partition: {partition_name}")

            if cpu_arch:
                print(f"    partition.cpu_arch: {cpu_arch}")
            else:
                print("    WARNING: partition.cpu_arch is empty!")

            if gpu_arch:
                print(f"    partition.gpu_arch: {gpu_arch}")
            else:
                print("    WARNING: partition.gpu_arch is empty!")

    # ------------------------------------------------------------------
    # Software catalogs
    # ------------------------------------------------------------------

    software_catalogs = offering.get("software_catalogs")

    if not software_catalogs:
        print("\nWARNING: software_catalogs is empty!")
        return

    print("\nSoftware catalogs:")

    for catalog in software_catalogs:
        catalog_name = (
            catalog.get("name")
            or catalog.get("catalog_name")
            or "<unnamed catalog>"
        )

        print(f"\n  Catalog: {catalog_name}")

        cpu_family = catalog.get("enabled_cpu_family")
        microarchitectures = catalog.get(
            "enabled_cpu_microarchitectures"
        )

        if cpu_family:
            print(f"    enabled_cpu_family: {cpu_family}")
        else:
            print("    WARNING: enabled_cpu_family is empty!")

        if microarchitectures:
            print(
                "    enabled_cpu_microarchitectures: "
                f"{microarchitectures}"
            )
        else:
            print(
                "    WARNING: "
                "enabled_cpu_microarchitectures is empty!"
            )


def main():
    offerings = get_all_offerings()

    print(f"Found {len(offerings)} offering(s).")

    for offering in offerings:
        print_architectures(offering)


if __name__ == "__main__":
    main()
