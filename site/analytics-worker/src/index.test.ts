import { describe, expect, it } from 'vitest'
import { collapseSmallCells, type DimensionCell } from './index'

describe('anonymous dimension rollups', () => {
  it('keeps cells of ten or more and folds smaller cells into other', () => {
    const cells: DimensionCell[] = [
      { metric: 'unique_windows', dimensionName: 'country', dimensionValue: 'US', value: 14 },
      { metric: 'unique_windows', dimensionName: 'country', dimensionValue: 'CA', value: 6 },
      { metric: 'unique_windows', dimensionName: 'country', dimensionValue: 'GB', value: 3 },
    ]
    expect(collapseSmallCells(cells)).toEqual([
      { metric: 'unique_windows', dimensionName: 'country', dimensionValue: 'US', value: 14 },
      { metric: 'unique_windows', dimensionName: 'country', dimensionValue: 'other', value: 9 },
    ])
  })

  it('never combines different metrics or dimensions', () => {
    const cells: DimensionCell[] = [
      { metric: 'unique_download', dimensionName: 'placement', dimensionValue: 'hero', value: 4 },
      { metric: 'unique_github', dimensionName: 'placement', dimensionValue: 'hero', value: 7 },
      { metric: 'unique_windows', dimensionName: 'device', dimensionValue: 'mobile', value: 5 },
    ]
    expect(collapseSmallCells(cells)).toEqual([
      { metric: 'unique_download', dimensionName: 'placement', dimensionValue: 'other', value: 4 },
      { metric: 'unique_github', dimensionName: 'placement', dimensionValue: 'other', value: 7 },
      { metric: 'unique_windows', dimensionName: 'device', dimensionValue: 'other', value: 5 },
    ])
  })

  it('keeps exact all-up funnel totals below the dimension threshold', () => {
    const cells: DimensionCell[] = [
      { metric: 'unique_download', dimensionName: 'all', dimensionValue: 'all', value: 3 },
      { metric: 'unique_github', dimensionName: 'all', dimensionValue: 'all', value: 5 },
    ]
    expect(collapseSmallCells(cells)).toEqual(cells)
  })
})
