import logging

from config.constants import (browse_question1, browse_question2,
                              generate_question1)
from pages.browsePage import BrowsePage
from pages.draftPage import DraftPage
from pages.generatePage import GeneratePage
from pages.homePage import HomePage

logger = logging.getLogger(__name__)


def test_DocGen_GOLDENPATH(login_logout):
    """Validate Golden path test case for Doc Gen Accelerator """

    page = login_logout
    logger.info("Step 1: Validate home page is loaded.")
    home_page = HomePage(page)
    logger.info("Step 2: Validate Browse page is loaded.")
    home_page.click_browse_button()
    browse_page = BrowsePage(page)
    logger.info("Step 3: Validate Browse- Prompts response.")
    browse_page.enter_a_question(browse_question1)
    browse_page.click_send_button()
    # validate response
    browse_page.validate_response_status(question_api=browse_question1)
    browse_page.click_expand_reference_in_response()
    browse_page.click_reference_link_in_response()
    browse_page.close_citation()

    browse_page.enter_a_question(browse_question2)
    browse_page.click_send_button()
    browse_page.click_expand_reference_in_response()
    browse_page.click_reference_link_in_response()
    browse_page.close_citation()
    logger.info("Step 4: Validate Generate Page is loaded.")
    browse_page.click_generate_button()
    logger.info("Step 5: Validate Generate- Prompts response.")
    browse_page.validate_response_status(question_api=browse_question2)
    generate_page = GeneratePage(page)
    generate_page.enter_a_question(generate_question1)
    generate_page.click_send_button()
    generate_page.validate_response_status(question_api=generate_question1)
    generate_page.click_generate_draft_button()
    logger.info("Step 6: Validate Generate Page is loaded.")
    draft_page = DraftPage(page)
    logger.info("Step 7: Validate Draft sections generated properly.")
    draft_page.check_draft_Sections()
