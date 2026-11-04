/**
 * Embeddable partner widgets (search forms and result lists) shown on the Book page and inside Trip essentials.
 *
 * To add one: in the Travelpayouts dashboard go to Tools -> Widgets, pick the program, generate the widget and
 * copy the URL out of the `<script src="...">` it gives you into `tp(...)` below. `category` must be one of the
 * partner categories (flights, car, activities, transfer, esim, luggage, bike, claims). Within a category the
 * first widget is the main one; the rest sit behind "More search options".
 *
 * Snippets run in a sandboxed iframe (see WidgetEmbed), so they cannot reach the app. Only use snippets from
 * your own Travelpayouts dashboard.
 *
 * Deliberately NOT embedded (their snippets are pinned to one fixed city, so they would show the wrong place for
 * most trips; they stay as plain partner links): Klook, Localrent, Welcome Pickups, WeGoTrip. Tiqets' and Kiwi.com's
 * snippets render blank when embedded. Intui's snippet is a whole landing page (FAQ, reviews...),
 * far too heavy; Kiwitaxi covers transfers. GetRentacar's snippet was an exact copy of Airalo's, so only Airalo has one.
 */
export interface Widget {
  id: string
  category: string
  title: string
  /** One plain sentence telling the user what this form does. */
  blurb: string
  html: string
  /** Initial height before the widget reports its real size. */
  minHeight?: number
  /** Only offered when the trip touches one of these regions ("europe", "asia"). Empty = worldwide. */
  onlyRegions?: string[]
}

/** A Travelpayouts widget script tag from its `src` URL. */
const tp = (src: string) => `<script async src="${src}" charset="utf-8"></script>`

export const WIDGETS: Widget[] = [
  {
    id: 'aviasales',
    category: 'flights',
    title: 'Flights and hotels',
    blurb: 'Search flights, or switch to the hotels tab to find a place to stay.',
    minHeight: 220,
    html: tp('https://tpemb.com/content?currency=usd&trs=595446&shmarker=800312&show_hotels=true&powered_by=true&locale=en&searchUrl=www.aviasales.com%2Fsearch&primary_override=%2332a8dd&color_button=%23e8b917&color_icons=%2332a8dd&dark=%23262626&light=%23FFFFFF&secondary=%23FFFFFF&special=%23C4C4C4&color_focused=%2332a8dd&border_radius=5&plain=false&promo_id=7879&campaign_id=100'),
  },

  {
    id: 'economybookings',
    category: 'car',
    title: 'Compare car rental prices',
    blurb: 'Pick up and drop off, then compare prices from many rental companies.',
    minHeight: 200,
    html: tp('https://tpemb.com/content?trs=595446&shmarker=800312&locale=en&powered_by=true&border_radius=5&plain=true&show_logo=true&color_background=%23ffca28&color_button=%2355a539&color_text=%23000000&color_input_text=%23000000&color_button_text=%23ffffff&promo_id=4480&campaign_id=10'),
  },
  {
    id: 'autoeurope',
    category: 'car',
    title: 'Car rental in Europe and the UK',
    blurb: 'Rental cars across Europe and the UK, including promotions.',
    minHeight: 200,
    onlyRegions: ['europe'],
    html: tp('https://tpemb.com/content?trs=595446&shmarker=800312&locale=en&powered_by=true&border_radius=5&plain=true&show_logo=true&color_background=%230b2033&color_button=%23e8b917&promo_id=4362&campaign_id=143'),
  },
  {
    id: 'qeeq',
    category: 'car',
    title: 'Car rental with a savings membership',
    blurb: 'Another place to compare rental prices.',
    minHeight: 200,
    html: tp('https://tpemb.com/content?trs=595446&shmarker=800312&locale=en&powered_by=true&campaign_id=172&promo_id=4850'),
  },

  {
    id: 'kiwitaxi',
    category: 'transfer',
    title: 'Airport transfer',
    blurb: 'Enter the airport and where you are going to see prices for a private ride.',
    minHeight: 220,
    html: tp('https://tpemb.com/content?currency=USD&trs=595446&shmarker=800312&locale=en&powered_by=true&transfer_options_limit=10&transfer_options=MCR&disable_currency_selector=true&hide_form_extras=true&hide_external_links=true&campaign_id=1&promo_id=3879'),
  },

  {
    id: 'airalo',
    category: 'esim',
    title: 'Find an eSIM for your destination',
    blurb: 'Choose the country you are visiting and pick a data plan.',
    minHeight: 200,
    html: tp('https://tpemb.com/content?trs=595446&shmarker=800312&locale=en&powered_by=true&color_button=%23f2685f&color_focused=%23f2685f&secondary=%23FFFFFF&dark=%2311100f&light=%23FFFFFF&special=%23C4C4C4&border_radius=5&plain=false&no_labels=true&promo_id=8588&campaign_id=541'),
  },

  {
    id: 'bikesbooking',
    category: 'bike',
    title: 'Rent a bike, scooter or motorcycle',
    blurb: 'Choose where and when, then compare local rental shops.',
    minHeight: 200,
    html: tp('https://tpemb.com/content?trs=595446&shmarker=800312&locale=en&powered_by=true&border_radius=5&plain=true&color_background=%23ffca28&color_button=%2355a539&promo_id=5472&campaign_id=57'),
  },

  {
    id: 'airhelp',
    category: 'claims',
    title: 'Check if you are owed compensation',
    blurb: 'Enter your flight to see if you can claim for a delay or cancellation. Free to check.',
    minHeight: 220,
    html: tp('https://tpemb.com/content?trs=595446&shmarker=800312&lang=en&powered_by=true&campaign_id=120&promo_id=8679'),
  },
  {
    id: 'compensair',
    category: 'claims',
    title: 'Second opinion on a flight claim',
    blurb: 'Same idea from another company.',
    minHeight: 220,
    html: tp('https://tpemb.com/content?trs=595446&shmarker=800312&locale=en&border_radius=5&plain=true&powered_by=true&promo_id=3408&campaign_id=86'),
  },
]

/** The widgets for one category, main one first. A widget with `onlyRegions` needs a matching region (none given = keep it, e.g. on the Book page). */
export function widgetsFor(category: string, regions?: ReadonlySet<string>): Widget[] {
  return WIDGETS.filter(
    (w) => w.category === category && (!regions || !w.onlyRegions?.length || w.onlyRegions.some((r) => regions.has(r))),
  )
}
