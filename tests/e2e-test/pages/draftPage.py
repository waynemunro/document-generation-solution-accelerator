from base.base import BasePage
from pytest_check import check


class DraftPage(BasePage):
    # Principal_Amount_and_Date = "div:nth-child(3) div:nth-child(2) span:nth-child(1) textarea:nth-child(1)"
    # Borrower_Information = "div:nth-child(3) div:nth-child(2) span:nth-child(1) textarea:nth-child(1)"
    # Payee_Information = "//div[3]//div[2]//span[1]//textarea[1]"
    Draft_Sections = "//textarea"
    Draft_headings = "//span[@class='fui-Text ___nl2uoq0 fk6fouc f4ybsrx f1i3iumi f16wzh4i fpgzoln f1w7gpdv f6juhto f1gl81tg f2jf649 fepr9ql febqm8h']"
    invalid_response = "The requested information is not available in the retrieved data. Please try another query or topic."
    invalid_response1 = "There was an issue fetching your data. Please try again."
    invalid_response2 = " "

    def __init__(self, page):
        self.page = page

    def check_draft_sections(self, timeout: float = 180.0, poll_interval: float = 0.5):
        """
        Waits for all <textarea> draft sections to load valid content using .input_value().
        Scrolls into view if needed, retries until timeout.
        Raises clear errors if validation fails.
        """
        import time
        from collections import defaultdict

        start_time = time.time()

        while time.time() - start_time < timeout:
            section_elements = self.page.locator(self.Draft_Sections)
            heading_elements = self.page.locator(self.Draft_headings)

            section_count = section_elements.count()
            heading_count = heading_elements.count()

            if section_count < 13 or heading_count < 13:
                print("[WAIT] Waiting for all sections to appear...")
                time.sleep(poll_interval)
                continue

            failed_sections = defaultdict(str)

            for i in range(section_count):
                section = section_elements.nth(i)

                try:
                    # Scroll into view and wait a bit for rendering
                    section.scroll_into_view_if_needed(timeout=2000)
                    self.page.wait_for_timeout(200)

                    # Extract content from <textarea>
                    section_text = section.input_value().strip()

                    if not section_text:
                        failed_sections[i] = "Empty"
                    elif section_text in (
                        self.invalid_response,
                        self.invalid_response1,
                    ):
                        failed_sections[i] = f"Invalid: {repr(section_text[:30])}"

                except Exception as e:
                    failed_sections[i] = f"Exception: {str(e)}"

            if not failed_sections:
                break  # ✅ All good
            else:
                print(f"[WAITING] Sections not ready yet: {failed_sections}")
                time.sleep(poll_interval)

        else:
            raise TimeoutError(
                f"❌ Timeout: These sections did not load valid content: {failed_sections}"
            )

        # ✅ Final validations after loading
        for i in range(section_count):
            section = section_elements.nth(i)
            heading = heading_elements.nth(i)

            section.scroll_into_view_if_needed(timeout=2000)
            self.page.wait_for_timeout(200)

            heading_text = heading.inner_text(timeout=3000).strip()
            content = section.input_value().strip()

            print(
                f"[VALIDATING] Section {i}: '{heading_text}' → {repr(content[:60])}..."
            )

            with check:
                check.is_not_none(content, f"❌ Section '{heading_text}' is None")
                check.not_equal(content, "", f"❌ Section '{heading_text}' is empty")
                check.not_equal(
                    content,
                    self.invalid_response,
                    f"❌ '{heading_text}' has invalid response",
                )
                check.not_equal(
                    content,
                    self.invalid_response1,
                    f"❌ '{heading_text}' has invalid response",
                )
