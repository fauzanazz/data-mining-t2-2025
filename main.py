import csv
import json
import logging
import os
import re
import sys
import time
from datetime import datetime, timezone
from tqdm import tqdm
from selenium import webdriver
from selenium.webdriver.chrome.service import Service
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
from selenium.common.exceptions import (
    TimeoutException,
    NoSuchElementException,
    StaleElementReferenceException,
    WebDriverException,
)
from webdriver_manager.chrome import ChromeDriverManager

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)

# Constants
DONOR_CARD_SELECTOR = "div.relative.mb-2.flex.rounded"
MAX_RETRIES = 3
RETRY_DELAY = 2
SCROLL_WAIT_TIME = 0.8
MAX_NO_NEW_DATA_SCROLLS = 5


def setup_driver():
    """Setup Chrome driver with appropriate options."""
    options = Options()
    options.add_argument("--headless")
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-dev-shm-usage")
    options.add_argument("--window-size=1200,800")
    options.add_argument(
        "user-agent=Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    )

    service = Service(ChromeDriverManager().install())
    driver = webdriver.Chrome(service=service, options=options)
    return driver


def scrape_campaign_metadata(driver, campaign_slug: str) -> dict:
    """
    Scrape campaign metadata from __NEXT_DATA__ JSON (fast method).

    Args:
        driver: Selenium webdriver instance
        campaign_slug: The campaign URL slug

    Returns:
        Dictionary with N (total donors), campaign_duration, and target_dana
    """
    url = f"https://kitabisa.com/campaign/{campaign_slug}/donors"
    logger.info(f"Scraping campaign metadata from: {url}")

    metadata = {
        "N": None,
        "campaign_duration": None,
        "target_dana": None,
    }

    try:
        driver.get(url)

        # Wait for page to load dynamically instead of fixed sleep
        WebDriverWait(driver, 10).until(
            EC.presence_of_element_located((By.ID, "__NEXT_DATA__"))
        )

        # Extract data from __NEXT_DATA__ script tag (faster than DOM scraping)
        try:
            next_data_script = driver.find_element(By.ID, "__NEXT_DATA__")
            next_data = json.loads(next_data_script.get_attribute("innerHTML"))

            data_campaign = next_data.get("props", {}).get("pageProps", {}).get("dataCampaign", {})

            if data_campaign:
                # N = donation_count
                if data_campaign.get("donation_count"):
                    metadata["N"] = str(data_campaign["donation_count"])

                # campaign_duration: calculate total duration from start to end
                campaign_duration = None

                # Try to get created_at and expired_at timestamps
                created_at = data_campaign.get("created_at")
                expired_at = data_campaign.get("expired_at")

                if created_at and expired_at:
                    try:
                        # Parse timestamps (handle both Unix timestamps and ISO format)
                        if isinstance(created_at, (int, float)):
                            start_date = datetime.fromtimestamp(created_at, tz=timezone.utc)
                        else:
                            start_date = datetime.fromisoformat(str(created_at).replace("Z", "+00:00"))

                        if isinstance(expired_at, (int, float)):
                            end_date = datetime.fromtimestamp(expired_at, tz=timezone.utc)
                        else:
                            end_date = datetime.fromisoformat(str(expired_at).replace("Z", "+00:00"))

                        campaign_duration = (end_date - start_date).days
                        metadata["campaign_duration"] = campaign_duration
                        logger.debug(f"Campaign duration calculated: {campaign_duration} days (from {start_date.date()} to {end_date.date()})")
                    except (ValueError, TypeError) as e:
                        logger.warning(f"Failed to parse campaign dates: {e}")

                # Fallback: if we couldn't calculate duration, store days_remaining as negative indicator
                if campaign_duration is None:
                    days_remaining = data_campaign.get("days_remaining")
                    if days_remaining is not None:
                        # Store as string to indicate it's only partial info
                        metadata["campaign_duration"] = f"{days_remaining} (days remaining only)"
                        logger.debug(f"Using days_remaining as fallback: {days_remaining}")

                # target_dana from donation_target
                target = data_campaign.get("donation_target")
                if target:
                    # Format as Rp with thousands separator
                    metadata["target_dana"] = f"Rp{target:,}".replace(",", ".")

                logger.info(f"Campaign metadata: {metadata}")
                return metadata

        except json.JSONDecodeError as e:
            logger.warning(f"Failed to parse __NEXT_DATA__ JSON: {e}")
        except Exception as e:
            logger.warning(f"Could not extract from __NEXT_DATA__: {e}")

        # Fallback to DOM scraping if __NEXT_DATA__ fails
        try:
            donation_section = driver.find_element(
                By.CSS_SELECTOR, '[data-testid="campaign-section-donation"]'
            )
            match = re.search(r'Donasi\s*([\d.,]+)', donation_section.text)
            if match:
                metadata["N"] = match.group(1).replace(".", "").replace(",", "")
        except NoSuchElementException:
            logger.debug("Donation section element not found")
        except Exception as e:
            logger.warning(f"Error extracting donation count from DOM: {e}")

        try:
            duration_elem = driver.find_element(
                By.CSS_SELECTOR, '[data-testid="campaign-donation-days-to-go"]'
            )
            metadata["campaign_duration"] = duration_elem.text.strip()
        except NoSuchElementException:
            logger.debug("Campaign duration element not found")
        except Exception as e:
            logger.warning(f"Error extracting campaign duration from DOM: {e}")

        try:
            target_elem = driver.find_element(
                By.CSS_SELECTOR, '[data-testid="campaign-donation-goal"]'
            )
            match = re.search(r'Rp\s*([\d.,]+)', target_elem.text)
            if match:
                metadata["target_dana"] = f"Rp{match.group(1)}"
        except NoSuchElementException:
            logger.debug("Target dana element not found")
        except Exception as e:
            logger.warning(f"Error extracting target dana from DOM: {e}")

        logger.info(f"Campaign metadata (from DOM fallback): {metadata}")

    except TimeoutException:
        logger.error(f"Timeout waiting for page to load: {url}")
    except Exception as e:
        logger.error(f"Error scraping campaign metadata: {e}")

    return metadata


def wait_for_new_content(driver, last_count: int, timeout: float = 2.0) -> int:
    """
    Wait for new donor cards to load after scrolling.

    Args:
        driver: Selenium webdriver instance
        last_count: Previous number of donor cards
        timeout: Maximum time to wait for new content

    Returns:
        Current count of donor cards
    """
    start_time = time.time()
    while time.time() - start_time < timeout:
        donor_cards = driver.find_elements(By.CSS_SELECTOR, DONOR_CARD_SELECTOR)
        current_count = len(donor_cards)
        if current_count > last_count:
            return current_count
        time.sleep(0.2)  # Small polling interval

    # Return current count even if no new content
    return len(driver.find_elements(By.CSS_SELECTOR, DONOR_CARD_SELECTOR))


def parse_donor_card(card) -> dict | None:
    """
    Parse a single donor card element with fallback selectors.

    Args:
        card: Selenium WebElement for the donor card

    Returns:
        Dictionary with donor data or None if parsing fails
    """
    # Name selectors (primary and fallbacks)
    name_selectors = [
        "span.text-body.font-bold",
        "span[class*='font-bold']",
        "div > span:first-child",
    ]

    # Amount selectors (primary and fallbacks)
    amount_selectors = [
        "strong[data-testid='total-donation']",
        "strong",
        "[class*='donation']",
    ]

    # Time selectors (primary and fallbacks)
    time_selectors = [
        "span.mt-1.text-xs.text-tundora",
        "span[class*='text-xs']",
        "span:last-child",
    ]

    name = None
    amount = None
    time_ago = None

    # Try each name selector
    for selector in name_selectors:
        try:
            name_elem = card.find_element(By.CSS_SELECTOR, selector)
            name = name_elem.text.strip()
            if name:
                break
        except NoSuchElementException:
            continue

    # Try each amount selector
    for selector in amount_selectors:
        try:
            amount_elem = card.find_element(By.CSS_SELECTOR, selector)
            amount = amount_elem.text.strip()
            if amount and ("Rp" in amount or amount.isdigit()):
                break
        except NoSuchElementException:
            continue

    # Try each time selector
    for selector in time_selectors:
        try:
            time_elem = card.find_element(By.CSS_SELECTOR, selector)
            time_ago = time_elem.text.strip()
            if time_ago and time_ago != name:  # Avoid getting name again
                break
        except NoSuchElementException:
            continue

    if name and amount:
        return {
            "name": name,
            "amount": amount,
            "time_ago": time_ago or "Unknown",
        }

    return None


def scrape_donors_with_retry(campaign_slug: str, max_retries: int = MAX_RETRIES) -> tuple[list[dict], dict]:
    """
    Scrape donors with retry logic for transient failures.

    Args:
        campaign_slug: The campaign URL slug
        max_retries: Maximum number of retry attempts

    Returns:
        Tuple of (List of donor dictionaries, Campaign metadata dictionary)
    """
    last_exception = None

    for attempt in range(max_retries):
        try:
            if attempt > 0:
                logger.info(f"Retry attempt {attempt + 1}/{max_retries}")
                time.sleep(RETRY_DELAY * attempt)  # Exponential backoff

            return scrape_donors(campaign_slug)

        except (TimeoutException, WebDriverException) as e:
            last_exception = e
            logger.warning(f"Attempt {attempt + 1} failed: {e}")
            continue
        except Exception as e:
            # For unexpected exceptions, log and re-raise
            logger.error(f"Unexpected error during scraping: {e}")
            raise

    # All retries exhausted
    logger.error(f"All {max_retries} attempts failed")
    raise last_exception or Exception("Scraping failed after all retries")


def scrape_donors(campaign_slug: str) -> tuple[list[dict], dict]:
    """
    Scrape ALL donor data from KitaBisa campaign by scrolling to the end.

    Args:
        campaign_slug: The campaign URL slug (e.g., 'masjidkemasjid')

    Returns:
        Tuple of (List of donor dictionaries, Campaign metadata dictionary)
    """
    driver = setup_driver()
    donors = []

    try:
        # Scrape campaign metadata (also loads the donors page)
        metadata = scrape_campaign_metadata(driver, campaign_slug)

        # Page is already loaded from metadata scraping, just wait for donor cards
        logger.info("Waiting for donor cards...")

        # Wait for donor cards to load using consistent selector
        WebDriverWait(driver, 10).until(
            EC.presence_of_element_located((By.CSS_SELECTOR, DONOR_CARD_SELECTOR))
        )

        last_card_count = 0
        no_new_data_count = 0
        scroll_count = 0

        logger.info("Scrolling to load all donors...")

        # Create progress bar for scrolling
        pbar = tqdm(desc="Loading donors", unit=" donors", dynamic_ncols=True)

        while no_new_data_count < MAX_NO_NEW_DATA_SCROLLS:
            # Scroll down to load more donors
            driver.execute_script("window.scrollTo(0, document.body.scrollHeight);")
            scroll_count += 1

            # Wait dynamically for new content instead of fixed sleep
            current_count = wait_for_new_content(driver, last_card_count, timeout=SCROLL_WAIT_TIME + 1.0)

            if current_count == last_card_count:
                no_new_data_count += 1
            else:
                no_new_data_count = 0
                # Update progress bar
                pbar.n = current_count
                pbar.refresh()

            last_card_count = current_count

        pbar.close()
        logger.info(f"Finished scrolling after {scroll_count} scrolls.")
        logger.info(f"Total donor cards found: {last_card_count}")
        logger.info("Parsing donor cards...")

        # Parse all donor cards with progress bar using consistent selector
        donor_cards = driver.find_elements(By.CSS_SELECTOR, DONOR_CARD_SELECTOR)

        failed_parses = 0
        for card in tqdm(donor_cards, desc="Parsing donors", unit=" donors"):
            try:
                donor_data = parse_donor_card(card)
                if donor_data:
                    donors.append(donor_data)
                else:
                    failed_parses += 1
            except StaleElementReferenceException:
                logger.debug("Stale element encountered, skipping card")
                failed_parses += 1
                continue
            except Exception as e:
                logger.warning(f"Error parsing donor card: {e}")
                failed_parses += 1
                continue

        if failed_parses > 0:
            logger.warning(f"Failed to parse {failed_parses} donor cards")

    finally:
        driver.quit()

    return donors, metadata


def save_to_csv(donors: list[dict], metadata: dict, filename: str):
    """Save donors data to CSV file (donor data only, metadata in JSON)."""
    if not donors:
        print("No donors to save.")
        return

    fieldnames = ["name", "amount", "time_ago"]
    with open(filename, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(donors)

    print(f"Saved {len(donors)} donors to {filename}")


def save_to_json(donors: list[dict], metadata: dict, filename: str):
    """Save donors data to JSON file with campaign metadata."""
    if not donors:
        print("No donors to save.")
        return

    data = {
        "campaign_metadata": metadata,
        "total_donors_scraped": len(donors),
        "donors": donors,
    }

    with open(filename, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)

    print(f"Saved {len(donors)} donors to {filename}")


def main():
    # Default values
    campaign_slug = "masjidkemasjid"

    # Parse command line arguments
    if len(sys.argv) > 1:
        campaign_slug = sys.argv[1]

    logger.info(f"Campaign: {campaign_slug}")
    logger.info("Scraping ALL donors (infinite scroll to end)")
    print("-" * 50)

    # Scrape donors and campaign metadata with retry logic
    donors, metadata = scrape_donors_with_retry(campaign_slug)

    if donors:
        # Create output folder with slug name
        output_folder = campaign_slug
        os.makedirs(output_folder, exist_ok=True)

        # Generate timestamp for filenames
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        base_filename = f"donors_{timestamp}"

        # Save to both CSV and JSON in the slug folder
        csv_path = os.path.join(output_folder, f"{base_filename}.csv")
        json_path = os.path.join(output_folder, f"{base_filename}.json")
        save_to_csv(donors, metadata, csv_path)
        save_to_json(donors, metadata, json_path)

        # Print campaign metadata
        print("\n" + "=" * 50)
        print("Campaign Metadata:")
        print("=" * 50)
        print(f"  N (Total Donatur): {metadata.get('N', 'N/A')}")
        duration = metadata.get('campaign_duration', 'N/A')
        if isinstance(duration, int):
            print(f"  Campaign Duration: {duration} days (total)")
        else:
            print(f"  Campaign Duration: {duration}")
        print(f"  Target Dana: {metadata.get('target_dana', 'N/A')}")

        # Print sample of scraped data
        print("\n" + "=" * 50)
        print("Sample of scraped donors:")
        print("=" * 50)
        for donor in donors[:5]:
            print(f"  {donor['name']}, {donor['amount']}, {donor['time_ago']}")

        if len(donors) > 5:
            print(f"  ... and {len(donors) - 5} more donors")
    else:
        print("No donors were scraped.")


if __name__ == "__main__":
    main()
